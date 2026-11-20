param(
  [string]$StateFile = '',
  [string]$StateDir = '',
  [Parameter(Mandatory = $true)][string]$AssetDir,
  [Parameter(Mandatory = $true)][string]$PrefsFile,
  [int]$ParentPid = 0,
  [int]$HostPid = 0,
  [string]$Snapshot = '',
  [switch]$SnapshotBubble,
  [string]$FrameDir = ''
)

# Claude娘 floating desktop pet. Reads the state file the mod writes and
# draws a transparent, always-on-top, draggable window.

$ErrorActionPreference = 'Stop'

# Only one Claude娘 at a time, whichever session starts her: a second window leaves at once (exit 3),
# and the one on screen shows every session, the freshest first.
$script:petLock = $null
if ($StateDir -ne '') {
  $created = $false
  $script:petLock = New-Object System.Threading.Mutex($true, 'Local\ClaudePetCompanion', [ref]$created)
  if (-not $created) { exit 3 }
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$utf8 = New-Object System.Text.UTF8Encoding($false)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PetNative {
  [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b")]
  public interface IVirtualDesktopManager {
    [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr hwnd, out int onCurrent);
    [PreserveSig] int GetWindowDesktopId(IntPtr hwnd, out Guid desktopId);
    [PreserveSig] int MoveWindowToDesktop(IntPtr hwnd, ref Guid desktopId);
  }
  [ComImport, Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")]
  public class VirtualDesktopManagerClass {}

  public static class Win {
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetLong(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetLong(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

    const int GWLP_HWNDPARENT = -8;
    // a window's owner can be changed after it is shown
    public static void SetOwner(IntPtr h, IntPtr owner) { SetLong(h, GWLP_HWNDPARENT, owner); }

    const int GWL_EXSTYLE = -20;
    const long WS_EX_TOOLWINDOW = 0x80, WS_EX_APPWINDOW = 0x40000;

    // a tool window is left out of Alt+Tab and the taskbar
    public static void HideFromAltTab(IntPtr h) {
      long ex = GetLong(h, GWL_EXSTYLE).ToInt64();
      ex = (ex | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;
      SetLong(h, GWL_EXSTYLE, new IntPtr(ex));
    }

    static IVirtualDesktopManager vdm;
    static IVirtualDesktopManager Vdm() {
      if (vdm == null) { try { vdm = (IVirtualDesktopManager)new VirtualDesktopManagerClass(); } catch { } }
      return vdm;
    }

    // moves our own window to the virtual desktop the other window is on; true when it moved
    public static bool FollowDesktop(IntPtr mine, IntPtr other) {
      var m = Vdm(); if (m == null) return false;
      Guid theirs, ours;
      if (m.GetWindowDesktopId(other, out theirs) != 0 || theirs == Guid.Empty) return false;
      if (m.GetWindowDesktopId(mine, out ours) != 0) return false;
      if (ours == theirs) return false;
      return m.MoveWindowToDesktop(mine, ref theirs) == 0;
    }
  }
}
'@

# The window of the app Claude Code runs in: the first ancestor process with a main window
function Find-HostWindow([int]$procId) {
  $p = $procId
  for ($i = 0; $i -lt 10 -and $p -gt 4; $i++) {
    $gp = Get-Process -Id $p -ErrorAction SilentlyContinue
    if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero) { return $gp.MainWindowHandle }
    $w = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
    if (-not $w) { break }
    $p = [int]$w.ParentProcessId
  }
  return [IntPtr]::Zero
}

function Read-Json([string]$path) {
  try {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $text = [IO.File]::ReadAllText($path, $utf8)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
  } catch { return $null }
}

$sizes = @{ small = 120; medium = 170; large = 230; huge = 300 }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude娘" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="False" ShowInTaskbar="False"
        ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        FontFamily="Microsoft YaHei UI" UseLayoutRounding="True">
  <StackPanel x:Name="Root" Orientation="Vertical" HorizontalAlignment="Center">
    <StackPanel x:Name="BubbleBox" HorizontalAlignment="Center" Opacity="0" IsHitTestVisible="False"
                RenderTransformOrigin="0.5,1">
      <StackPanel.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="BubbleScale" ScaleX="0.96" ScaleY="0.96"/>
          <TranslateTransform x:Name="BubbleShift" Y="6"/>
        </TransformGroup>
      </StackPanel.RenderTransform>
      <Border x:Name="Bubble" CornerRadius="12" Padding="11,8,11,9" MaxWidth="250" MinWidth="150"
              Background="#F8FFFDFB" BorderThickness="2" BorderBrush="#E8692C" Margin="8,8,8,0">
        <Border.Effect>
          <DropShadowEffect BlurRadius="10" ShadowDepth="1" Opacity="0.25"/>
        </Border.Effect>
        <StackPanel x:Name="Content">
          <TextBlock x:Name="Label" FontWeight="Bold" FontSize="13" Foreground="#E8692C"/>
          <TextBlock x:Name="Line" FontSize="12" FontStyle="Italic" Foreground="#4A3B33" TextWrapping="Wrap" Margin="0,2,0,0"/>
          <TextBlock x:Name="Detail" FontSize="11" Foreground="#8A7F78" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
          <StackPanel x:Name="TaskBox" Margin="0,6,0,0">
            <DockPanel>
              <TextBlock x:Name="TaskCount" DockPanel.Dock="Right" FontSize="11" Foreground="#8A7F78"/>
              <TextBlock x:Name="TaskText" FontSize="11" Foreground="#4A3B33" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <ProgressBar x:Name="TaskBar" Height="5" Minimum="0" Maximum="1" Margin="0,2,0,0"
                         Foreground="#E8692C" Background="#F1E4DA" BorderThickness="0"/>
          </StackPanel>
          <StackPanel x:Name="UsageBox" Margin="0,6,0,0"/>
        </StackPanel>
      </Border>
      <Path x:Name="Tail" Data="M 0 0 L 9 10 L 18 0 Z" Fill="#F8FFFDFB" Stroke="#E8692C" StrokeThickness="2"
            HorizontalAlignment="Center" Margin="0,-2,0,0"/>
    </StackPanel>
    <Grid x:Name="Stage" HorizontalAlignment="Center" Margin="14,0,14,2">
      <Ellipse x:Name="Shadow" Fill="#000000" Opacity="0.13" Height="10" VerticalAlignment="Bottom"
               HorizontalAlignment="Center" RenderTransformOrigin="0.5,0.5">
        <Ellipse.RenderTransform>
          <ScaleTransform/>
        </Ellipse.RenderTransform>
      </Ellipse>
      <Grid x:Name="Body" Margin="0,32,0,4" RenderTransformOrigin="0.5,1">
        <Grid.RenderTransform>
          <TransformGroup>
            <ScaleTransform/>
            <RotateTransform/>
            <TranslateTransform/>
          </TransformGroup>
        </Grid.RenderTransform>
        <Image x:Name="PetA" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"
               HorizontalAlignment="Center" VerticalAlignment="Bottom"/>
        <Image x:Name="PetB" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"
               HorizontalAlignment="Center" VerticalAlignment="Bottom" Opacity="0"/>
      </Grid>
    </Grid>
  </StackPanel>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)
$names = 'Root','BubbleBox','BubbleScale','BubbleShift','Bubble','Content','Label','Line','Detail','TaskBox','TaskCount','TaskText','TaskBar','UsageBox','Tail','Stage','Shadow','Body','PetA','PetB'
$ui = @{}
foreach ($n in $names) { $ui[$n] = $win.FindName($n) }

# ---- images ----
$images = @{}
function Get-Sprite([string]$mood) {
  if ($images.ContainsKey($mood)) { return $images[$mood] }
  $file = Join-Path $AssetDir ($mood + '.png')
  if (-not (Test-Path -LiteralPath $file)) { $file = Join-Path $AssetDir 'idle.png' }
  $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
  $bmp.BeginInit()
  $bmp.UriSource = New-Object System.Uri($file)
  $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  $bmp.EndInit()
  $bmp.Freeze()
  $images[$mood] = $bmp
  return $bmp
}

function Get-Brush([string]$hex) {
  try { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) } catch { return [System.Windows.Media.Brushes]::DarkOrange }
}

# ---- sound: a chime when a task is done ----
$script:dataDir = Split-Path -Parent $PrefsFile
$script:soundPrefs = Join-Path $script:dataDir 'sound.json'
$script:defaultSound = Join-Path (Split-Path -Parent $AssetDir) 'sounds\done.wav'
$script:player = New-Object System.Windows.Media.MediaPlayer
$script:soundOn = $true
$script:soundVolume = 0.6
$script:soundFile = ''

# which file: the one named in Claude Code's settings, else the one picked from the menu, else the default
function Get-SoundFile {
  if ($script:soundFile -ne '' -and (Test-Path -LiteralPath $script:soundFile)) { return $script:soundFile }
  $picked = Read-Json $script:soundPrefs
  if ($null -ne $picked -and $picked.file -and (Test-Path -LiteralPath ([string]$picked.file))) { return [string]$picked.file }
  return $script:defaultSound
}

function Play-Chime([bool]$force = $false) {
  $on = if ($null -ne $script:local.sound) { $script:local.sound } else { $script:soundOn }
  if (-not $on -and -not $force) { return }
  try {
    $script:player.Open((New-Object System.Uri((Get-SoundFile))))
    $script:player.Volume = $script:soundVolume
    $script:player.Position = [TimeSpan]::Zero
    $script:player.Play()
  } catch {}
}

# copy the chosen file next to the window's own settings, so it stays even if the original moves
function Select-CustomSound {
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Title = '选择 Claude娘的提示音'
  $dlg.Filter = '音频文件 (*.wav;*.mp3;*.wma;*.m4a)|*.wav;*.mp3;*.wma;*.m4a'
  if ($dlg.ShowDialog($win) -ne $true) { return }
  try {
    $ext = [IO.Path]::GetExtension($dlg.FileName)
    $dest = Join-Path $script:dataDir ('custom-sound' + $ext)
    Get-ChildItem -LiteralPath $script:dataDir -Filter 'custom-sound.*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $dlg.FileName -Destination $dest -Force
    [IO.File]::WriteAllText($script:soundPrefs, (@{ file = $dest } | ConvertTo-Json -Compress), $utf8)
    Play-Chime $true
  } catch {}
}

function Reset-CustomSound {
  Remove-Item -LiteralPath $script:soundPrefs -Force -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $script:dataDir -Filter 'custom-sound.*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Play-Chime $true
}

# ---- local, per-window choices (a settings change from Claude Code resets them) ----
$script:local = @{ size = $null; bubble = $null; topmost = $null; sound = $null }
$script:lastConfigVersion = -1
$script:lastMood = ''
$script:lastWrite = [datetime]::MinValue
$script:state = $null
$script:bubbleUntil = [datetime]::MinValue
$script:hovering = $false
$script:bubbleMode = 'change'
$script:bubbleSeconds = 5
$script:autoLevel = 'brief'
$script:pokeLevel = 'full'
$script:bubbleLevel = 'brief'
$script:hasTasks = $false
$script:hasUsage = $false
$script:hasDetail = $false

# brief: the status, what she is doing and the task progress; full: everything
function Set-Level([string]$level) {
  $script:bubbleLevel = $level
  $full = $level -eq 'full'
  $ui.Line.Visibility = if ($full) { 'Visible' } else { 'Collapsed' }
  $ui.Detail.Visibility = if ($script:hasDetail) { 'Visible' } else { 'Collapsed' }
  $ui.TaskBox.Visibility = if ($script:hasTasks) { 'Visible' } else { 'Collapsed' }
  $ui.UsageBox.Visibility = if ($full -and $script:hasUsage) { 'Visible' } else { 'Collapsed' }
}
$script:lastBubbleKey = ''

function Show-BubbleFor([double]$seconds) {
  $until = [datetime]::Now.AddSeconds($seconds)
  if ($until -gt $script:bubbleUntil) { $script:bubbleUntil = $until }
}

function New-Ease([string]$kind) {
  if ($kind -eq '') { return $null }
  $e = New-Object System.Windows.Media.Animation.CubicEase
  $e.EasingMode = switch ($kind) { 'o' { 'EaseOut' } 'i' { 'EaseIn' } default { 'EaseInOut' } }
  return $e
}

# A keyframe track: rows of @(ms, value, ease), the first at 0.
function New-Track([object[]]$frames) {
  $anim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
  foreach ($f in $frames) {
    $k = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame
    $k.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($f[0]))
    $k.Value = $f[1]
    if ($f.Count -gt 2) { $k.EasingFunction = New-Ease $f[2] }
    [void]$anim.KeyFrames.Add($k)
  }
  $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  return $anim
}

$bodyPaths = @{
  sx  = '(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)'
  sy  = '(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)'
  rot = '(UIElement.RenderTransform).(TransformGroup.Children)[1].(RotateTransform.Angle)'
  x   = '(UIElement.RenderTransform).(TransformGroup.Children)[2].(TranslateTransform.X)'
  y   = '(UIElement.RenderTransform).(TransformGroup.Children)[2].(TranslateTransform.Y)'
}
$rest = @{ sx = 1.0; sy = 1.0; rot = 0.0; x = 0.0; y = 0.0 }
$shadowPath = '(UIElement.RenderTransform).(ScaleTransform.ScaleX)'

# keyframes per mood: each property's loop, from rest back to rest
function Get-MoodTracks([string]$mood) {
  switch ($mood) {
    'thinking' { return @{
      rot = @(@(0, 0), @(1000, -1.6, 'io'), @(3000, 1.6, 'io'), @(4000, 0, 'io'))
      y   = @(@(0, 0), @(1500, -2.5, 'io'), @(3000, 0, 'io'))
    } }
    'working' { return @{
      y  = @(@(0, 0), @(200, -2.5, 'o'), @(400, 0, 'i'))
      sy = @(@(0, 1), @(200, 1.008, 'o'), @(400, 0.995, 'i'), @(460, 1, 'o'))
    } }
    'waiting' { return @{
      rot = @(@(0, 0), @(800, -2.4, 'io'), @(2400, 2.4, 'io'), @(3200, 0, 'io'))
      y   = @(@(0, 0), @(1600, -2, 'io'), @(3200, 0, 'io'))
    } }
    'done' { return @{
      y  = @(@(0, 0), @(130, 0), @(430, -18, 'o'), @(720, 0, 'i'), @(1400, 0))
      sy = @(@(0, 1), @(130, 0.93, 'o'), @(320, 1.05, 'o'), @(620, 1, 'io'), @(780, 0.95, 'o'), @(980, 1, 'io'), @(1400, 1))
      sx = @(@(0, 1), @(130, 1.06, 'o'), @(320, 0.97, 'o'), @(620, 1, 'io'), @(780, 1.04, 'o'), @(980, 1, 'io'), @(1400, 1))
      shadow = @(@(0, 1), @(130, 1.05, 'o'), @(430, 0.72, 'o'), @(720, 1, 'i'), @(1400, 1))
    } }
    'error' { return @{
      x = @(@(0, 0), @(70, -5, 'o'), @(150, 5, 'io'), @(230, -4, 'io'), @(310, 3, 'io'), @(390, -1.5, 'io'), @(480, 0, 'i'), @(2800, 0))
      y = @(@(0, 0), @(400, 2, 'o'), @(2400, 2), @(2800, 0, 'io'))
    } }
    'sleep' { return @{
      y  = @(@(0, 0), @(1900, -1.2, 'io'), @(3800, 0, 'io'))
      sy = @(@(0, 1), @(1900, 1.02, 'io'), @(3800, 1, 'io'))
    } }
    default { return @{
      y  = @(@(0, 0), @(1300, -3, 'io'), @(2600, 0, 'io'))
      sy = @(@(0, 1), @(1300, 1.012, 'io'), @(2600, 1, 'io'))
    } }
  }
}

function Add-ToBoard($sb, $anim, $target, [string]$path) {
  [System.Windows.Media.Animation.Storyboard]::SetTarget($anim, $target)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($anim, (New-Object System.Windows.PropertyPath($path)))
  [void]$sb.Children.Add($anim)
}

function Set-Animation([string]$mood) {
  $sb = New-Object System.Windows.Media.Animation.Storyboard
  $settle = [TimeSpan]::FromMilliseconds(260)
  $tracks = Get-MoodTracks $mood
  # every property glides back to rest from the pose on screen, then the mood's loop starts there
  foreach ($key in $bodyPaths.Keys) {
    $back = New-Object System.Windows.Media.Animation.DoubleAnimation
    $back.To = $rest[$key]; $back.Duration = $settle; $back.EasingFunction = New-Ease 'o'
    Add-ToBoard $sb $back $ui.Body $bodyPaths[$key]
    if ($tracks.ContainsKey($key)) {
      $loop = New-Track $tracks[$key]
      $loop.BeginTime = $settle
      Add-ToBoard $sb $loop $ui.Body $bodyPaths[$key]
    }
  }
  $sback = New-Object System.Windows.Media.Animation.DoubleAnimation
  $sback.To = 1; $sback.Duration = $settle; $sback.EasingFunction = New-Ease 'o'
  Add-ToBoard $sb $sback $ui.Shadow $shadowPath
  if ($tracks.ContainsKey('shadow')) {
    $sl = New-Track $tracks['shadow']; $sl.BeginTime = $settle
    Add-ToBoard $sb $sl $ui.Shadow $shadowPath
  }
  # SnapshotAndReplace: the new animations take over from the values on screen, never jump
  $sb.Begin($ui.Body, [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace, $true)
}

function Start-To($target, $prop, [double]$to, [int]$ms, [string]$ease = 'o') {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation
  $a.To = $to; $a.Duration = [TimeSpan]::FromMilliseconds($ms); $a.EasingFunction = New-Ease $ease
  $target.BeginAnimation($prop, $a, [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)
}
function Start-Fade($target, [double]$to, [int]$ms, [string]$ease = 'o') {
  Start-To $target ([System.Windows.UIElement]::OpacityProperty) $to $ms $ease
}

# cross-fade to a new expression: the hidden image takes the new sprite and fades in over the old one
$script:front = 'PetA'
function Set-Sprite($bmp) {
  $cur = $ui[$script:front]
  $nextName = if ($script:front -eq 'PetA') { 'PetB' } else { 'PetA' }
  $nxt = $ui[$nextName]
  if ($null -eq $cur.Source) {
    $cur.Source = $bmp; $cur.Opacity = 1
    return
  }
  $nxt.Source = $bmp
  [System.Windows.Controls.Panel]::SetZIndex($nxt, 1); [System.Windows.Controls.Panel]::SetZIndex($cur, 0)
  Start-Fade $nxt 1 280 'io'
  Start-Fade $cur 0 280 'io'
  $script:front = $nextName
}

function Add-UsageRow([string]$label, [double]$pct, [string]$right, [string]$color) {
  $panel = New-Object System.Windows.Controls.StackPanel
  $panel.Margin = '0,2,0,0'
  $dock = New-Object System.Windows.Controls.DockPanel
  $r = New-Object System.Windows.Controls.TextBlock
  $r.Text = $right; $r.FontSize = 11; $r.Foreground = Get-Brush '#8A7F78'
  [System.Windows.Controls.DockPanel]::SetDock($r, 'Right')
  $l = New-Object System.Windows.Controls.TextBlock
  $l.Text = $label; $l.FontSize = 11; $l.Foreground = Get-Brush '#4A3B33'
  [void]$dock.Children.Add($r); [void]$dock.Children.Add($l)
  $bar = New-Object System.Windows.Controls.ProgressBar
  $bar.Height = 4; $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = [Math]::Min(100, [Math]::Max(0, $pct))
  $bar.Foreground = Get-Brush $color; $bar.Background = Get-Brush '#F1E4DA'; $bar.BorderThickness = 0
  [void]$panel.Children.Add($dock); [void]$panel.Children.Add($bar)
  [void]$ui.UsageBox.Children.Add($panel)
}

$script:bubbleShown = $false
$script:lastTextKey = ''
$script:poking = $false
$script:pokeUntil = [datetime]::MinValue
# after the fade-out, the next bubble starts from the auto level again
$script:resetLevel = New-Object System.Windows.Threading.DispatcherTimer
$script:resetLevel.Interval = [TimeSpan]::FromMilliseconds(220)
$script:resetLevel.Add_Tick({
  $script:resetLevel.Stop()
  if (-not $script:bubbleShown) { Set-Level $script:autoLevel }
})

# double-click: the bubble pops open with the poke level, with a springy overshoot, and she does a little hop
function Invoke-Poke {
  $script:poking = $true
  Set-Level $script:pokeLevel
  # its own timer, so a double-click shows the details whatever the bubble mode
  $script:pokeUntil = [datetime]::Now.AddSeconds([Math]::Max($script:bubbleSeconds, 6))
  $script:bubbleShown = $true
  $ui.BubbleBox.IsHitTestVisible = $true
  $sx = [System.Windows.Media.ScaleTransform]::ScaleXProperty
  $sy = [System.Windows.Media.ScaleTransform]::ScaleYProperty
  $ty = [System.Windows.Media.TranslateTransform]::YProperty
  $back = New-Object System.Windows.Media.Animation.BackEase
  $back.EasingMode = 'EaseOut'; $back.Amplitude = 0.6
  foreach ($prop in @($sx, $sy)) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = 0.78; $a.To = 1; $a.Duration = [TimeSpan]::FromMilliseconds(420); $a.EasingFunction = $back
    $ui.BubbleScale.BeginAnimation($prop, $a)
  }
  $up = New-Object System.Windows.Media.Animation.DoubleAnimation
  $up.From = 14; $up.To = 0; $up.Duration = [TimeSpan]::FromMilliseconds(420); $up.EasingFunction = $back
  $ui.BubbleShift.BeginAnimation($ty, $up)
  $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
  $fade.From = 0.2; $fade.To = 1; $fade.Duration = [TimeSpan]::FromMilliseconds(160)
  $ui.BubbleBox.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

  # her reaction: the head-pat sprite, a squash and a happy sway, then back to her mood
  Start-Special 'pat' 2300 { $script:poking = $false; Set-Sprite (Get-Sprite $script:lastMood); Set-Animation $script:lastMood; if ($null -ne $script:state) { Apply-State $script:state } }
}

# one-off moments that take over the sprite and the motion for a while, then hand back to the mood
$script:special = ''
$script:farewellPlayed = $false
$script:specialTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:specialAfter = $null
$script:specialTimer.Add_Tick({
  $script:specialTimer.Stop()
  $script:special = ''
  $after = $script:specialAfter; $script:specialAfter = $null
  if ($null -ne $after) { & $after; return }
  Set-Sprite (Get-Sprite $script:lastMood)
  Set-Animation $script:lastMood
  if ($null -ne $script:state) { Apply-State $script:state }
})

$specialTracks = @{
  hello = @{
    rot = @(@(0, 0), @(260, -3, 'o'), @(560, 2.6, 'io'), @(860, -2.2, 'io'), @(1160, 1.6, 'io'), @(1460, -0.8, 'io'), @(1700, 0, 'io'), @(2600, 0))
    y   = @(@(0, 0), @(180, -8, 'o'), @(380, 0, 'i'), @(470, 1.5, 'o'), @(600, 0, 'io'), @(2600, 0))
    sy  = @(@(0, 1), @(380, 1, 'o'), @(450, 0.95, 'o'), @(620, 1, 'io'), @(2600, 1))
    sx  = @(@(0, 1), @(380, 1, 'o'), @(450, 1.04, 'o'), @(620, 1, 'io'), @(2600, 1))
    x   = @(@(0, 0), @(2600, 0))
  }
  bye = @{
    rot = @(@(0, 0), @(380, -2.4, 'io'), @(860, 2.4, 'io'), @(1340, -2, 'io'), @(1700, 0, 'io'), @(2200, 0))
    y   = @(@(0, 0), @(1700, 0), @(2200, 6, 'i'))
    sy  = @(@(0, 1), @(2200, 1))
    sx  = @(@(0, 1), @(2200, 1))
    x   = @(@(0, 0), @(2200, 0))
  }
  pat = @{
    sy  = @(@(0, 1), @(110, 0.9, 'o'), @(300, 1.05, 'o'), @(480, 0.98, 'io'), @(620, 1, 'io'), @(2300, 1))
    sx  = @(@(0, 1), @(110, 1.07, 'o'), @(300, 0.97, 'o'), @(480, 1.01, 'io'), @(620, 1, 'io'), @(2300, 1))
    y   = @(@(0, 0), @(110, 2, 'o'), @(320, -6, 'o'), @(520, 0, 'i'), @(2300, 0))
    rot = @(@(0, 0), @(620, 0), @(950, -3, 'io'), @(1350, 3, 'io'), @(1750, -2, 'io'), @(2100, 0, 'io'), @(2300, 0))
    x   = @(@(0, 0), @(2300, 0))
  }
}
$specialText = @{
  hello = @{ label = '你好呀～'; line = '今天也一起加油吧！'; detail = 'Claude娘上线啦' }
  bye   = @{ label = '拜拜～'; line = '下次见哦！'; detail = 'Claude娘去休息啦' }
  pat   = @{ line = '嘿嘿……被摸头了～' }
}

function Set-SpecialText {
  if ($script:special -eq '') { return }
  $t = $specialText[$script:special]
  if ($t.label) { $ui.Label.Text = $t.label }
  if ($t.line) { $ui.Line.Text = $t.line }
  if ($t.detail) { $ui.Detail.Text = $t.detail; $script:hasDetail = $true; Set-Level $script:bubbleLevel }
}

function Start-Special([string]$kind, [int]$ms, [scriptblock]$after = $null) {
  $script:special = $kind
  $script:specialAfter = $after
  Set-Sprite (Get-Sprite $kind)
  $sb = New-Object System.Windows.Media.Animation.Storyboard
  foreach ($key in $specialTracks[$kind].Keys) {
    $t = New-Track $specialTracks[$kind][$key]
    $t.RepeatBehavior = New-Object System.Windows.Media.Animation.RepeatBehavior(1)
    Add-ToBoard $sb $t $ui.Body $bodyPaths[$key]
  }
  $sb.Begin($ui.Body, [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace, $true)
  Set-SpecialText
  $script:specialTimer.Stop()
  $script:specialTimer.Interval = [TimeSpan]::FromMilliseconds($ms)
  $script:specialTimer.Start()
}

function Start-Hello {
  # she fades in and rises a little as she waves
  $ui.Root.Opacity = 0
  Start-Fade $ui.Root 1 450 'o'
  Start-Special 'hello' 2600
  Set-Level $script:autoLevel
  Show-BubbleFor ([Math]::Max($script:bubbleSeconds, 3))
  Update-Bubble
}

function Start-Bye {
  if ($script:farewellPlayed) { return }
  $script:farewellPlayed = $true
  $script:pokeUntil = [datetime]::Now.AddSeconds(5)
  Set-Level 'brief'
  Update-Bubble
  Start-Special 'bye' 1900 {
    # then she fades away and the window closes
    Start-Fade $ui.Root 0 450 'i'
    $script:closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:closeTimer.Interval = [TimeSpan]::FromMilliseconds(480)
    $script:closeTimer.Add_Tick({ $script:closeTimer.Stop(); $win.Close() })
    $script:closeTimer.Start()
  }
}

function Update-Bubble([bool]$instant = $false) {
  $mode = $script:bubbleMode
  $now = [datetime]::Now
  $show = ($mode -eq 'always') -or $script:hovering -or ($mode -eq 'change' -and $now -lt $script:bubbleUntil) -or ($now -lt $script:pokeUntil)
  if ($show -eq $script:bubbleShown -and -not $instant) { return }
  if ($show -and -not $script:bubbleShown -and -not $script:poking) { Set-Level $script:autoLevel }
  $script:bubbleShown = $show
  $ui.BubbleBox.IsHitTestVisible = $show
  $sx = [System.Windows.Media.ScaleTransform]::ScaleXProperty
  $sy = [System.Windows.Media.ScaleTransform]::ScaleYProperty
  $ty = [System.Windows.Media.TranslateTransform]::YProperty
  $op = [System.Windows.UIElement]::OpacityProperty
  if ($instant) {
    $ui.BubbleScale.BeginAnimation($sx, $null); $ui.BubbleScale.BeginAnimation($sy, $null)
    $ui.BubbleShift.BeginAnimation($ty, $null); $ui.BubbleBox.BeginAnimation($op, $null)
    $ui.BubbleBox.Opacity = if ($show) { 1 } else { 0 }
    $ui.BubbleScale.ScaleX = if ($show) { 1 } else { 0.96 }
    $ui.BubbleScale.ScaleY = $ui.BubbleScale.ScaleX
    $ui.BubbleShift.Y = if ($show) { 0 } else { 6 }
    return
  }
  if ($show) {
    Start-Fade $ui.BubbleBox 1 220 'o'
    Start-To $ui.BubbleScale $sx 1 280 'o'; Start-To $ui.BubbleScale $sy 1 280 'o'
    Start-To $ui.BubbleShift $ty 0 280 'o'
  } else {
    Start-Fade $ui.BubbleBox 0 180 'i'
    $script:resetLevel.Stop(); $script:resetLevel.Start()
    Start-To $ui.BubbleScale $sx 0.96 180 'i'; Start-To $ui.BubbleScale $sy 0.96 180 'i'
    Start-To $ui.BubbleShift $ty 6 180 'i'
  }
}

function Apply-State($s) {
  if ($null -eq $s) { return }
  $cfg = $s.config
  if ($null -ne $cfg -and $cfg.version -ne $script:lastConfigVersion) {
    $script:lastConfigVersion = $cfg.version
    $script:local = @{ size = $null; bubble = $null; topmost = $null; sound = $null }
  }
  if ($null -ne $cfg -and $null -ne $cfg.sound) {
    $script:soundOn = [bool]$cfg.sound
    if ($cfg.soundVolume) { $script:soundVolume = [double]$cfg.soundVolume }
    $script:soundFile = [string]$cfg.soundFile
  }
  $size = if ($script:local.size) { $script:local.size } elseif ($cfg) { $cfg.size } else { 'medium' }
  $bubble = if ($script:local.bubble) { $script:local.bubble } elseif ($cfg) { $cfg.bubble } else { 'change' }
  $topmost = if ($null -ne $script:local.topmost) { $script:local.topmost } elseif ($cfg) { [bool]$cfg.topmost } else { $false }
  $seconds = if ($cfg -and $cfg.bubbleSeconds) { [double]$cfg.bubbleSeconds } else { 5 }
  $script:bubbleSeconds = $seconds
  $script:autoLevel = if ($cfg -and $cfg.autoLevel) { [string]$cfg.autoLevel } else { 'brief' }
  $script:pokeLevel = if ($cfg -and $cfg.pokeLevel) { [string]$cfg.pokeLevel } else { 'full' }
  $showUsage = if ($cfg) { [bool]$cfg.showUsage } else { $true }

  $h = $sizes[[string]$size]; if (-not $h) { $h = 170 }
  $ui.PetA.Height = $h; $ui.PetB.Height = $h
  $ui.Shadow.Width = $h * 0.55
  $win.Topmost = $topmost

  $mood = [string]$s.mood
  if ($mood -ne $script:lastMood) {
    if ($mood -eq 'done' -and $script:lastMood -ne '') { Play-Chime }
    if ($script:special -eq '') {
      Set-Sprite (Get-Sprite $mood)
      Set-Animation $mood
    }
    $script:lastMood = $mood
  }

  # a change worth a look: the mood, or a task finished
  $taskDone = if ($null -ne $s.tasks) { [int]$s.tasks.done } else { 0 }
  $key = $mood + '|' + $taskDone
  if ($key -ne $script:lastBubbleKey) {
    $script:lastBubbleKey = $key
    Show-BubbleFor $seconds
  }
  $script:bubbleMode = [string]$bubble
  Update-Bubble

  # a soft refresh of the words when they change while the bubble is up
  $textKey = [string]$s.label + '|' + [string]$s.detail
  if ($script:bubbleShown -and $textKey -ne $script:lastTextKey) {
    $ui.Content.Opacity = 0.35
    Start-Fade $ui.Content 1 240 'o'
  }
  $script:lastTextKey = $textKey

  $brush = Get-Brush ([string]$s.color)
  $ui.Bubble.BorderBrush = $brush; $ui.Tail.Stroke = $brush; $ui.Label.Foreground = $brush
  $ui.Label.Text = [string]$s.label
  $ui.Line.Text = [string]$s.line
  $ui.Detail.Text = [string]$s.detail
  $script:hasDetail = -not [string]::IsNullOrEmpty([string]$s.detail)

  $t = $s.tasks
  if ($null -ne $t -and $t.total -gt 0) {
    $script:hasTasks = $true
    $ui.TaskText.Text = [string]$t.text
    $ui.TaskCount.Text = ('  {0}/{1}' -f $t.done, $t.total)
    $ui.TaskBar.Value = [double]$t.done / [double]$t.total
  } else { $script:hasTasks = $false }

  $ui.UsageBox.Children.Clear()
  if ($showUsage -and $null -ne $s.usage) {
    foreach ($row in @($s.usage.rows)) {
      if ($null -ne $row) { Add-UsageRow ([string]$row.label) ([double]$row.percent) ([string]$row.right) ([string]$row.color) }
    }
    if ($s.usage.note) {
      $n = New-Object System.Windows.Controls.TextBlock
      $n.Text = [string]$s.usage.note; $n.FontSize = 10.5; $n.Foreground = Get-Brush '#8A7F78'; $n.Margin = '0,3,0,0'
      [void]$ui.UsageBox.Children.Add($n)
    }
  }
  $script:hasUsage = $ui.UsageBox.Children.Count -gt 0
  if (-not $script:bubbleShown) { $script:bubbleLevel = $script:autoLevel }
  Set-Level $script:bubbleLevel
  Set-SpecialText
  # the mod asks for a goodbye before it closes the window
  if ($s.farewell -eq $true -and ([datetime]::UtcNow - $script:lastWrite).TotalSeconds -lt 10) { Start-Bye }
}

# ---- position ----
function Save-Position {
  try {
    $p = @{ left = [int]$win.Left; top = [int]$win.Top } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($PrefsFile, $p, $utf8)
  } catch {}
}
function Restore-Position {
  $p = Read-Json $PrefsFile
  $wa = [System.Windows.SystemParameters]::WorkArea
  if ($null -ne $p -and $p.left -ge ($wa.Left - 100) -and $p.left -le ($wa.Right - 60) -and $p.top -ge ($wa.Top - 100) -and $p.top -le ($wa.Bottom - 60)) {
    $win.Left = $p.left; $win.Top = $p.top
  } else {
    $win.Left = $wa.Right - 300; $win.Top = $wa.Bottom - 520
  }
}

# ---- interaction ----
$ui.Root.Add_MouseEnter({ $script:hovering = $true; Update-Bubble })
$ui.Root.Add_MouseLeave({ $script:hovering = $false; Update-Bubble })

$ui.Root.Add_MouseLeftButtonDown({
  param($sender, $e)
  if ($e.ClickCount -eq 2) {
    Invoke-Poke
    return
  }
  try { $win.DragMove() } catch {}
  Save-Position
})

function New-Item-Menu([string]$header, [scriptblock]$onClick, [bool]$checked = $false) {
  $mi = New-Object System.Windows.Controls.MenuItem
  $mi.Header = $header
  $mi.IsChecked = $checked
  $mi.Add_Click($onClick)
  return $mi
}

$win.Add_MouseRightButtonUp({
  $menu = New-Object System.Windows.Controls.ContextMenu
  $sizeMenu = New-Object System.Windows.Controls.MenuItem
  $sizeMenu.Header = '大小'
  foreach ($pair in @(@('small', '小'), @('medium', '中'), @('large', '大'), @('huge', '特大'))) {
    $key = $pair[0]
    $item = New-Item-Menu $pair[1] ([scriptblock]::Create("`$script:local.size = '$key'; Apply-State `$script:state"))
    [void]$sizeMenu.Items.Add($item)
  }
  [void]$menu.Items.Add($sizeMenu)
  $bubbleMenu = New-Object System.Windows.Controls.MenuItem
  $bubbleMenu.Header = '气泡'
  foreach ($pair in @(@('change', '状态变化时显示'), @('always', '总是显示'), @('never', '隐藏'))) {
    $key = $pair[0]
    $item = New-Item-Menu $pair[1] ([scriptblock]::Create("`$script:local.bubble = '$key'; Apply-State `$script:state"))
    [void]$bubbleMenu.Items.Add($item)
  }
  [void]$menu.Items.Add($bubbleMenu)
  $soundMenu = New-Object System.Windows.Controls.MenuItem
  $soundMenu.Header = '提示音'
  $soundIsOn = if ($null -ne $script:local.sound) { $script:local.sound } else { $script:soundOn }
  [void]$soundMenu.Items.Add((New-Item-Menu '任务完成时播放' { $cur = if ($null -ne $script:local.sound) { $script:local.sound } else { $script:soundOn }; $script:local.sound = -not $cur } $soundIsOn))
  [void]$soundMenu.Items.Add((New-Item-Menu '试听' { Play-Chime $true }))
  [void]$soundMenu.Items.Add((New-Object System.Windows.Controls.Separator))
  [void]$soundMenu.Items.Add((New-Item-Menu '选择自定义提示音…' { Select-CustomSound }))
  [void]$soundMenu.Items.Add((New-Item-Menu '恢复默认提示音' { Reset-CustomSound }))
  [void]$menu.Items.Add($soundMenu)
  [void]$menu.Items.Add((New-Item-Menu '置顶' { $script:local.topmost = -not $win.Topmost; Apply-State $script:state } $win.Topmost))
  [void]$menu.Items.Add((New-Item-Menu '回到右下角' {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Left = $wa.Right - $win.ActualWidth - 20; $win.Top = $wa.Bottom - $win.ActualHeight - 10; Save-Position }))
  [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
  [void]$menu.Items.Add((New-Item-Menu '收起桌宠（输入 /pet 再叫我）' { Start-Bye }))
  $menu.IsOpen = $true
})

# keep the bottom edge in place when the bubble grows or shrinks
$win.Add_SizeChanged({
  param($sender, $e)
  if ($e.HeightChanged -and $e.PreviousSize.Height -gt 0) {
    $win.Top = $win.Top - ($e.NewSize.Height - $e.PreviousSize.Height)
  }
})

# ---- polling ----
# the state file to show: the one given, or the session that wrote last
function Get-StateFile {
  if ($StateDir -eq '') { return $StateFile }
  $f = Get-ChildItem -LiteralPath $StateDir -Filter 'state-*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if ($null -eq $f) { return '' }
  return $f.FullName
}

function Poll {
  try {
    $file = Get-StateFile
    if ($file -ne '' -and (Test-Path -LiteralPath $file)) {
      $w = [IO.File]::GetLastWriteTimeUtc($file)
      if ($w -ne $script:lastWrite) {
        $s = Read-Json $file
        if ($null -ne $s) {
          $script:dozing = $false
          $script:lastWrite = $w
          $script:state = $s
          Apply-State $s
        }
      }
    }
  } catch {}
}

# a session that ended long ago leaves its file behind: tidy those away
if ($StateDir -ne '') {
  Get-ChildItem -LiteralPath $StateDir -Filter 'state-*.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -lt [datetime]::UtcNow.AddDays(-2) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

$script:startFile = Get-StateFile
if ($script:startFile -ne '') {
  $script:lastWrite = [IO.File]::GetLastWriteTimeUtc($script:startFile)
  $script:state = Read-Json $script:startFile
}
Apply-State $script:state

if ($Snapshot -ne '') {
  if ($SnapshotBubble) { $script:bubbleMode = 'always' } else { $script:bubbleMode = 'never' }
  Update-Bubble $true
  $ui.Root.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
  $ui.Root.Arrange((New-Object System.Windows.Rect($ui.Root.DesiredSize)))
  $ui.Root.UpdateLayout()
  $w = [int][Math]::Ceiling($ui.Root.ActualWidth); $hh = [int][Math]::Ceiling($ui.Root.ActualHeight)
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $hh, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($ui.Root)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
  exit 0
}

Restore-Position

# test mode: run off-screen, play a scripted sequence and render the window's own frames to files
if ($FrameDir -ne '') {
  $win.Left = -4000; $win.Top = -4000
  $win.Add_ContentRendered({ Start-Hello })
  $script:frameStart = [datetime]::Now
  $script:steps = [System.Collections.ArrayList]@(
    @(120, 'shot', 'hello-a'), @(500, 'shot', 'hello-b'), @(900, 'shot', 'idle'),
    @(1000, 'mood', 'done'),
    @(1300, 'shot', 'done-a'), @(1420, 'shot', 'done-b'), @(1540, 'shot', 'done-c'), @(1660, 'shot', 'done-d'), @(1800, 'shot', 'done-e'),
    @(2600, 'mood', 'error'),
    @(2700, 'shot', 'bubble-in'), @(3100, 'shot', 'bubble-up'),
    @(3200, 'bubble', 'never'),
    @(3600, 'hover', 'on'), @(3700, 'shot', 'hover-in'), @(4000, 'shot', 'hover-up'),
    @(4050, 'hover', 'off'), @(4120, 'shot', 'hover-out'), @(4400, 'shot', 'hover-gone'),
    @(4500, 'poke', ''), @(4560, 'shot', 'poke-a'), @(4660, 'shot', 'poke-b'), @(4780, 'shot', 'poke-c'), @(5100, 'shot', 'poke-d'),
    @(6000, 'shot', 'pat-sway'), @(7100, 'shot', 'pat-after'),
    @(7300, 'bye', ''), @(7700, 'shot', 'bye-a'), @(8600, 'shot', 'bye-b'), @(9350, 'shot', 'bye-fade'),
    @(9900, 'exit', '')
  )
  $ft = New-Object System.Windows.Threading.DispatcherTimer
  $ft.Interval = [TimeSpan]::FromMilliseconds(15)
  $ft.Add_Tick({
    $ms = ([datetime]::Now - $script:frameStart).TotalMilliseconds
    while ($script:steps.Count -gt 0 -and $script:steps[0][0] -le $ms) {
      $step = $script:steps[0]; $script:steps.RemoveAt(0)
      switch ($step[1]) {
        'mood' { $script:state.mood = $step[2]; Apply-State $script:state }
        'bubble' { $script:local.bubble = $step[2]; Apply-State $script:state }
        'hover' { $script:hovering = ($step[2] -eq 'on'); Update-Bubble }
        'poke' { Invoke-Poke }
        'bye' { Start-Bye }
        'shot' {
          $w = [int][Math]::Ceiling($ui.Root.ActualWidth); $hh = [int][Math]::Ceiling($ui.Root.ActualHeight)
          $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $hh, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
          $rtb.Render($ui.Root)
          $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
          $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
          $fs = [IO.File]::Create((Join-Path $FrameDir ($step[2] + '.png'))); $enc.Save($fs); $fs.Close()
        }
        'exit' { $win.Close() }
      }
    }
  })
  $ft.Start()
}

$script:hostHwnd = [IntPtr]::Zero
if ($HostPid -gt 0) {
  $hp = Get-Process -Id $HostPid -ErrorAction SilentlyContinue
  if ($hp) { $script:hostHwnd = $hp.MainWindowHandle }
} elseif ($ParentPid -gt 0) {
  $script:hostHwnd = Find-HostWindow $ParentPid
}
if ($script:hostHwnd -ne [IntPtr]::Zero) {
  # owned by the Claude app's window: same level as it, minimized with it, gone from Alt+Tab
  (New-Object System.Windows.Interop.WindowInteropHelper($win)).Owner = $script:hostHwnd
}
$win.Add_SourceInitialized({
  [PetNative.Win]::HideFromAltTab((New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle)
})

function Write-PetLog([string]$text) {
  try { [IO.File]::AppendAllText((Join-Path $script:dataDir 'pet.log'), ([datetime]::Now.ToString('s') + ' ' + $text + "`r`n"), $utf8) } catch {}
}

$script:dozing = $false
function Watch-Quiet {
  if ($null -eq $script:state -or $script:special -ne '') { return }
  $quiet = ([datetime]::UtcNow - $script:lastWrite).TotalMinutes -gt 10
  if ($quiet -and $script:lastMood -ne 'sleep') {
    $script:dozing = $true
    $nap = $script:state | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $nap.mood = 'sleep'; $nap.label = '睡着了 zzZ'; $nap.line = '（呼……呼……）'; $nap.detail = ''; $nap.color = '#8a8fa8'
    Apply-State $nap
  }
}

function Follow-Host {
  if ($HostPid -gt 0) {
    $hp = Get-Process -Id $HostPid -ErrorAction SilentlyContinue
    if (-not $hp) { Write-PetLog 'the Claude app closed'; $win.Close(); return }
    # the app may show its window anew (from the tray, say): own the new one
    $now = $hp.MainWindowHandle
    if ($now -ne [IntPtr]::Zero -and $now -ne $script:hostHwnd) {
      $script:hostHwnd = $now
      $mine0 = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
      [PetNative.Win]::SetOwner($mine0, $now)
    }
  }
  $hh = $script:hostHwnd
  if ($hh -eq [IntPtr]::Zero) { return }
  if (-not [PetNative.Win]::IsWindow($hh)) {
    if ($HostPid -gt 0) { return }
    Write-PetLog 'the host window closed'; $win.Close(); return
  }
  $mine = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
  if ($mine -eq [IntPtr]::Zero) { return }
  try { [void][PetNative.Win]::FollowDesktop($mine, $hh) } catch {}
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:ticks = 0
$timer.Add_Tick({
  Poll
  Update-Bubble
  $script:ticks++
  if (($script:ticks % 3) -eq 0) { Follow-Host }
  if (($script:ticks % 10) -eq 0) { Watch-Quiet }
})
$timer.Start()

# Show, not ShowDialog: a dialog would disable its owner, Claude Code's window
$win.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
$win.Show()
if ($FrameDir -eq '') { Start-Hello }
[System.Windows.Threading.Dispatcher]::Run()
