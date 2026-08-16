# dsh-task-widget — Windows 桌面独立小组件（液态玻璃任务台）原生渲染器。
# PowerShell + WPF：无边框、始终置顶、深/浅色跟随系统、任务完成 Windows 系统通知。
#
# v0.5.0 重写（玻璃 + 交互）：
#   * 真·液态玻璃：Win11 走 DWM 合成器级 Acrylic 背景（DWMWA_SYSTEMBACKDROP_TYPE=3），
#     由 DWM 做真实高斯模糊（GPU 加速、零闪烁、自动处理多屏/DPI），不再截屏背后桌面。
#     顶部加 SpecGlow / UsageGloss 径向高光（光打在玻璃上的漫反射）。Win10 无此能力，
#     降级为纯色半透明 + 顶部高光（视觉接近玻璃感但不模糊桌面）。
#   * 透明度真正可调：alpha（窗口整体不透明度）→ $win.Opacity；cardAlpha → 卡片着色强度。
#   * 圆角：Win11 DWMWA_WINDOW_CORNER_PREFERENCE；Win10 CreateRoundRectRgn 区域裁剪。
#   * 通知：Windows 系统通知（WinRT Toast + AUMID，回退托盘气泡）。
#   * 系统托盘图标：作为通知来源，右键可退出。
#   * 位置预设（四角吸附）+ 拖动结束磁性吸附（≤48px 自动贴最近角落并持久化）。
#   * 用量卡可开关（关闭后小窗缩高，仅任务列表）；点击用量卡打开 DSH 用量页。
#   * 运行中任务显示「运行中 · 1m 23s」计时（基于 updatedAt，1s 滚动）。
#   * 余额未配置 API Key 时显示「未配置 API Key」，不再干瘪的 —。
#   * 用量卡取「最近更新的运行中会话」为主会话；Token 用量以「本回合」为主、累计为副标。
#
# 由宿主守护（lib/index.js）派生：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File widget.ps1
#                  -BaseUrl http://127.0.0.1:<port>/dsh-task-widget
#                  -CommandFile <widget>/.command.json
#
# 数据：轮询 /api/snapshot（2s），通知用快照内 events 增量。
# 控制：轮询 .command.json（500ms）——宿主写 show/hide/toggle/quit/config，本脚本执行后删除。
#
# 注意：本文件必须保持 UTF-8 带 BOM（Windows PowerShell 5.1 无 BOM 时按 ANSI 读取，
# 中文注释/字符串会乱码并导致解析失败）。
param(
  [string]$BaseUrl = 'http://127.0.0.1:5650/dsh-task-widget',
  [string]$CommandFile = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not $CommandFile) { $CommandFile = Join-Path $PSScriptRoot '.command.json' }

# ── 用户配置（软件内调整：强调色 / 透明度 / 锁定 / 位置 / 用量卡）────────
#   alpha       → 窗口整体不透明度 40..100（真正改变整窗透明度）
#   cardAlpha   → 卡片着色强度 40..100（玻璃着色深浅）
#   preset      → 位置预设 topRight / topLeft / bottomRight / bottomLeft
#   usageHidden → 是否隐藏用量卡
$script:cfg = @{
  accent      = '#4D9FFF'
  alpha       = 100
  cardAlpha   = 100
  locked      = $false
  preset      = 'topRight'
  usageHidden = $false
}
$script:cfgFile = Join-Path $PSScriptRoot '.config.json'
try {
  if (Test-Path $script:cfgFile) {
    $saved = Get-Content $script:cfgFile -Raw | ConvertFrom-Json
    if ($saved.accent -and $saved.accent -match '^#[0-9A-Fa-f]{6}$') { $script:cfg.accent = $saved.accent }
    if ($null -ne $saved.alpha -and [int]$saved.alpha -ge 40 -and [int]$saved.alpha -le 100) { $script:cfg.alpha = [int]$saved.alpha }
    if ($null -ne $saved.cardAlpha -and [int]$saved.cardAlpha -ge 40 -and [int]$saved.cardAlpha -le 100) { $script:cfg.cardAlpha = [int]$saved.cardAlpha }
    if ($null -ne $saved.locked) { $script:cfg.locked = [bool]$saved.locked }
    if ($saved.preset -and @('topRight','topLeft','bottomRight','bottomLeft') -contains $saved.preset) { $script:cfg.preset = $saved.preset }
    if ($null -ne $saved.usageHidden) { $script:cfg.usageHidden = [bool]$saved.usageHidden }
  }
} catch {}

# Win32 P/Invoke：圆角裁剪（Win10 区域）/ DWM 圆角偏好 / DWM 背景类型 / 强制重绘
Add-Type -Namespace DshW -Name Native -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
[DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int w, int h);
[DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
[DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);
'@

$isWin11 = $env:OS -eq "Windows_NT" -and [Environment]::OSVersion.Version.Build -ge 22000
$script:acrylicOn = $isWin11   # Win11 才走 DWM Acrylic 真模糊；Win10 降级纯色

# ── XAML 布局 ────────────────────────────────────────────────────────
# 事件一律不写在 XAML 属性里（XamlReader 无法为 PS 函数建委托，会抛异常），
# 统一在下方 FindName 之后用 Add_* 接线。
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSH 任务台" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
        Width="340" Height="512" FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei" UseLayoutRounding="True">
  <Grid Margin="12,10,12,12">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 主卡（任务区）：柔和投影 + 玻璃卡片（Acrylic 时透出 DWM 模糊） -->
    <Grid Grid.Row="0">
      <Border x:Name="MainShadow" CornerRadius="22" Background="#0A0F1A" Opacity="0.30" IsHitTestVisible="False">
        <Border.Effect><BlurEffect Radius="20"/></Border.Effect>
      </Border>
      <Border x:Name="Card" CornerRadius="20" BorderThickness="1" ClipToBounds="True" Background="Transparent" Cursor="SizeAll">
        <Grid>
          <Border x:Name="SpecGlow" CornerRadius="20" IsHitTestVisible="False" Panel.ZIndex="0"/>
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="30"/>
          </Grid.RowDefinitions>
          <!-- 任务列表（滚动区） -->
          <ScrollViewer x:Name="Body" Grid.Row="0" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled" Padding="12,10,12,4" Panel.ZIndex="1">
            <StackPanel>
              <StackPanel x:Name="TaskPanel"/>
              <TextBlock x:Name="Offline" Text="与 DSH 服务断开连接，重连中…" FontSize="10.5" Margin="2,6,0,0" Visibility="Collapsed"/>
            </StackPanel>
          </ScrollViewer>
          <!-- 页脚：更新时间 + 位置锁定（右下角） -->
          <Grid Grid.Row="1" Panel.ZIndex="1">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="FootLeft" Text="—" FontSize="9" VerticalAlignment="Center" Margin="14,0,0,0"/>
            <Button x:Name="LockBtn" Grid.Column="1" Width="26" Height="24" Margin="0,0,10,0" VerticalAlignment="Center" Background="Transparent" BorderThickness="0" Cursor="Hand" ToolTip="锁定位置（锁定后不可拖动）">
              <Button.Style>
                <Style TargetType="Button">
                  <Setter Property="Background" Value="Transparent"/>
                  <Setter Property="BorderThickness" Value="0"/>
                  <Setter Property="Padding" Value="0"/>
                  <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
                  <Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="1" ScaleY="1"/></Setter.Value></Setter>
                  <Style.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="0.85"/></Trigger>
                    <Trigger Property="IsPressed" Value="True"><Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.94" ScaleY="0.94"/></Setter.Value></Setter></Trigger>
                  </Style.Triggers>
                </Style>
              </Button.Style>
              <TextBlock x:Name="LockGlyph" Text="&#xE785;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Button>
          </Grid>
        </Grid>
      </Border>
    </Grid>

    <!-- Token 用量卡（独立卡片，固定接在主卡底下；可隐藏） -->
    <Grid Grid.Row="1" Margin="0,10,0,0" x:Name="UsageGrid">
      <Border x:Name="UsageShadow" CornerRadius="18" Background="#0A0F1A" Opacity="0.26" IsHitTestVisible="False">
        <Border.Effect><BlurEffect Radius="16"/></Border.Effect>
      </Border>
      <Border x:Name="UsageCard" CornerRadius="16" BorderThickness="1" ClipToBounds="True" Background="Transparent" Cursor="Hand" ToolTip="点击打开 DSH 用量页">
        <Grid>
          <Border x:Name="UsageGloss" CornerRadius="16" IsHitTestVisible="False" Panel.ZIndex="0"/>
          <StackPanel Margin="12,11,12,11" Panel.ZIndex="1">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="UHead" Text="用量" FontSize="11" Grid.Column="0"/>
              <TextBlock x:Name="USrc" Text="" FontSize="9" Grid.Column="1" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
            </Grid>
            <Grid Margin="0,8,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,10,8">
                <TextBlock x:Name="UTknL" Text="本回合 Token" FontSize="9.5"/>
                <TextBlock x:Name="UTkn" Text="—" FontSize="17" FontWeight="Bold"/>
                <TextBlock x:Name="UTknSub" Text="" FontSize="8.5" Margin="0,1,0,0"/>
              </StackPanel>
              <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,0,8">
                <TextBlock x:Name="USpendL" Text="当前花费" FontSize="9.5"/>
                <TextBlock x:Name="USpend" Text="—" FontSize="17" FontWeight="Bold"/>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,10,0">
                <TextBlock x:Name="URemTknL" Text="剩余 Token 量" FontSize="9.5"/>
                <TextBlock x:Name="URemTkn" Text="—" FontSize="17" FontWeight="Bold"/>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="1">
                <TextBlock x:Name="UQuotaL" Text="剩余额度" FontSize="9.5"/>
                <TextBlock x:Name="UQuota" Text="—" FontSize="17" FontWeight="Bold"/>
              </StackPanel>
            </Grid>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$reader = [System.Windows.Markup.XamlReader]::Parse($xaml)
$win = $reader
$names = @("Card","MainShadow","Body","LockBtn","LockGlyph","SpecGlow",
           "UsageGrid","UsageCard","UsageShadow","UsageGloss","UHead","USrc",
           "UTkn","UTknL","UTknSub","USpend","USpendL","URemTkn","URemTknL","UQuota","UQuotaL",
           "TaskPanel","Offline","FootLeft")
$u = @{}
foreach ($n in $names) { $u[$n] = $win.FindName($n) }

# ── 主题刷子 ────────────────────────────────────────────────────────
function New-Brush([string]$hex, [int]$alpha = 255) {
  $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
  return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb($alpha, $c.R, $c.G, $c.B))
}
function New-Color([string]$hex, [int]$alpha = 255) {
  $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
  return [System.Windows.Media.Color]::FromArgb($alpha, $c.R, $c.G, $c.B)
}
# 顶部高光（光打在玻璃上的漫反射）：白 → 透明
function New-Sheen([int]$topA) {
  $g = New-Object System.Windows.Media.LinearGradientBrush
  $g.StartPoint = New-Object System.Windows.Point(0,0)
  $g.EndPoint = New-Object System.Windows.Point(0,1)
  [void]$g.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb($topA,255,255,255), 0.0))
  [void]$g.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0,255,255,255), 0.55))
  return $g
}
# 行背景渐变（hover 提亮）
function New-Grad([object[]]$stops) {
  $g = New-Object System.Windows.Media.LinearGradientBrush
  $g.StartPoint = New-Object System.Windows.Point(0,0)
  $g.EndPoint = New-Object System.Windows.Point(1,1)
  foreach ($s in $stops) { [void]$g.GradientStops.Add($s) }
  return $g
}

$script:cur = $null
function Build-Paint([bool]$light) {
  $ck = [double]$script:cfg.cardAlpha / 100.0   # 卡片着色强度
  if ($light) {
    return @{
      text     = (New-Brush '#1F2430')
      dim      = (New-Brush '#5A6272')
      faint    = (New-Brush '#8A92A5')
      shade    = (New-Brush '#1F2430' 28)
      surface  = '#FFFFFF'
      cardRow  = (New-Brush $script:cfg.accent 22)
      cardRowB = (New-Brush $script:cfg.accent 46)
      rowTop   = (New-Brush '#FFFFFF' 80)
      rowBot   = (New-Brush '#FFFFFF' 34)
      live     = (New-Brush '#0FA968')
      idle     = (New-Brush '#9AA3B8')
      err      = (New-Brush '#D6454F')
      warn     = (New-Brush '#B26A00')
      accent1  = (New-Brush $script:cfg.accent)
      borderA  = 220
      ck       = $ck
    }
  }
  return @{
    text     = (New-Brush '#F2F4F8')
    dim      = (New-Brush '#9BA3B4')
    faint    = (New-Brush '#6E7688')
    shade    = (New-Brush '#000000' 60)
    surface  = '#232833'
    cardRow  = (New-Brush $script:cfg.accent 22)
    cardRowB = (New-Brush $script:cfg.accent 44)
    rowTop   = (New-Brush '#FFFFFF' 22)
    rowBot   = (New-Brush '#FFFFFF' 8)
    live     = (New-Brush '#34D399')
    idle     = (New-Brush '#6E7688')
    err      = (New-Brush '#F87171')
    warn     = (New-Brush '#FBBF24')
    accent1  = (New-Brush $script:cfg.accent)
    borderA  = 200
    ck       = $ck
  }
}

function Apply-Theme([bool]$light) {
  $p = Build-Paint $light
  $script:cur = $p
  if ($script:acrylicOn) {
    # 真·液态玻璃：窗口底色 = DWM Acrylic 着色（深/浅 + 随 cardAlpha 的低不透明），
    # 真正的模糊由 DWM 合成器在背后完成；卡片透出模糊背景。
    $tintA = [int]($p.ck * 70)
    if ($tintA -lt 18) { $tintA = 18 }
    $baseCol = if ($light) { '#FFFFFF' } else { '#0E1320' }
    $win.Background = (New-Brush $baseCol $tintA)
    $u.Card.Background = $null
    $u.UsageCard.Background = $null
  } else {
    # Win10 降级：纯色半透明卡片（底色不透明度由 cardAlpha 控制）
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $cardBg = New-Brush $p.surface
    $cardBg.Opacity = $p.ck
    $u.Card.Background = $cardBg
    $u.UsageCard.Background = $cardBg
  }
  # 顶部高光（光打在玻璃上）
  $u.SpecGlow.Background = (New-Sheen 70)
  $u.UsageGloss.Background = (New-Sheen 55)
  # 强调色描边（统一宽度/颜色，两卡一致）
  $border = New-Brush $script:cfg.accent $p.borderA
  $u.Card.BorderBrush = $border
  $u.UsageCard.BorderBrush = $border
  # 投影
  $u.MainShadow.Background = $p.shade
  $u.UsageShadow.Background = $p.shade
  # 用量卡文字
  $u.UHead.Foreground = $p.faint
  $u.USrc.Foreground = $p.faint
  $u.UTknSub.Foreground = $p.dim
  foreach ($pair in @(@("UTkn",$p.text),@("USpend",$p.text),@("URemTkn",$p.text),@("UQuota",$p.text))) {
    $u.($pair[0]).Foreground = $pair[1]; $u.($pair[0]).Typography.NumeralAlignment = [System.Windows.FontNumeralAlignment]::Tabular
  }
  foreach ($pair in @(@("UTknL",$p.dim),@("USpendL",$p.dim),@("URemTknL",$p.dim),@("UQuotaL",$p.dim),@("UTknSub",$p.dim))) {
    $u.($pair[0]).Foreground = $pair[1]
  }
  $u.Offline.Foreground = $p.err
  $u.FootLeft.Foreground = $p.faint
  $u.FootLeft.Typography.NumeralAlignment = [System.Windows.FontNumeralAlignment]::Tabular
  # 窗口整体不透明度（真正可调的“透明度”）
  $win.Opacity = [double]$script:cfg.alpha / 100.0
  # 主题切换时一并重绘已存在的任务行
  Repaint-Rows
  # 本环境 WPF 失效传播不可靠：强制重绘使主题/配置立即生效
  if ($script:hwnd -ne [IntPtr]::Zero) {
    try { [void][DshW.Native]::RedrawWindow($script:hwnd, [IntPtr]::Zero, [IntPtr]::Zero, 0x0001 -bor 0x0002 -bor 0x0080) } catch {}
  }
}

function Is-LightTheme {
  try {
    $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
    return ($v.AppsUseLightTheme -eq 1)
  } catch { return $false }
}

# ── 圆角：真正调用 OS 圆角 ──────────────────────────────────────────
$script:DWMWA_WINDOW_CORNER_PREFERENCE = 33
function Apply-RoundCorners {
  if ($script:hwnd -eq [IntPtr]::Zero) { return }
  try {
    if ($isWin11) {
      $pref = 2
      [void][DshW.Native]::DwmSetWindowAttribute($script:hwnd, $script:DWMWA_WINDOW_CORNER_PREFERENCE, [ref]$pref, 4)
    } else {
      $r = 20
      $hrgn = [DshW.Native]::CreateRoundRectRgn(0, 0, [int]$win.Width, [int]$win.Height, $r, $r)
      [void][DshW.Native]::SetWindowRgn($script:hwnd, $hrgn, $true)
    }
  } catch {}
}

# ── DWM Acrylic 真高斯模糊（仅 Win11）──────────────────────────────
# DWMWA_SYSTEMBACKDROP_TYPE = 38；值 3 = DWMSBT_TRANSIENTWINDOW（Acrylic）。
# 合成器级模糊：GPU 加速、零闪烁、自动处理多屏与 DPI，无需窗口激活（区别于旧的 Acrylic 策略）。
$script:DWMWA_SYSTEMBACKDROP_TYPE = 38
function Apply-Acrylic {
  if ($script:hwnd -eq [IntPtr]::Zero) { return }
  if (-not $script:acrylicOn) { return }
  try {
    $v = 3
    [void][DshW.Native]::DwmSetWindowAttribute($script:hwnd, $script:DWMWA_SYSTEMBACKDROP_TYPE, [ref]$v, 4)
  } catch {}
}

# ── 布局：位置预设 + 用量卡显隐 + 窗口高度 ─────────────────────────
function Apply-Layout {
  if ($script:cfg.usageHidden) {
    $u.UsageGrid.Visibility = 'Collapsed'
    $win.Height = 360
  } else {
    $u.UsageGrid.Visibility = 'Visible'
    $win.Height = 512
  }
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $x = $wa.Right - $win.Width - 20
  $y = $wa.Top + 20
  switch ($script:cfg.preset) {
    'topLeft'    { $x = $wa.Left + 20; $y = $wa.Top + 20 }
    'topRight'   { $x = $wa.Right - $win.Width - 20; $y = $wa.Top + 20 }
    'bottomLeft' { $x = $wa.Left + 20; $y = $wa.Bottom - $win.Height - 20 }
    'bottomRight'{ $x = $wa.Right - $win.Width - 20; $y = $wa.Bottom - $win.Height - 20 }
  }
  $win.Left = $x; $win.Top = $y
  Apply-RoundCorners
}

# ── 配置持久化 ──────────────────────────────────────────────────────
function Save-Cfg {
  try {
    $o = @{
      accent = $script:cfg.accent
      alpha = $script:cfg.alpha
      cardAlpha = $script:cfg.cardAlpha
      locked = $script:cfg.locked
      preset = $script:cfg.preset
      usageHidden = $script:cfg.usageHidden
    }
    Set-Content -Path $script:cfgFile -Value ($o | ConvertTo-Json) -Encoding utf8
  } catch {}
}

# ── 格式化工具 ──────────────────────────────────────────────────────
function Fmt-Tokens([double]$n) {
  if ($null -eq $n -or [double]::IsNaN($n)) { return "—" }
  if ($n -lt 1000) { return [math]::Round($n).ToString() }
  if ($n -lt 1e6) { return ([math]::Round($n/1e3*10)/10).ToString() + "K" }
  return ([math]::Round($n/1e6*10)/10).ToString() + "M"
}
function Fmt-Money([double]$n, [string]$cur) {
  if ($null -eq $n -or [double]::IsNaN($n)) { return "—" }
  $sym = if ($cur -eq "USD") { "$" } else { "¥" }
  return $sym + ($n.ToString("0.00"))
}
function Fmt-Ago([long]$ts) {
  if ($ts -le 0) { return "—" }
  $d = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ts
  if ($d -lt 0) { $d = 0 }
  if ($d -lt 10000) { return "刚刚" }
  if ($d -lt 60000) { return [math]::Floor($d/1e3).ToString() + " 秒前" }
  if ($d -lt 3600000) { return [math]::Floor($d/60e3).ToString() + " 分钟前" }
  if ($d -lt 86400000) { return [math]::Floor($d/3600e3).ToString() + " 小时前" }
  return ([DateTimeOffset]::FromUnixTimeMilliseconds($ts).ToLocalTime().ToString("HH:mm"))
}
function Fmt-Dur([long]$ms) {
  if ($ms -le 0) { return "" }
  $s = [math]::Floor($ms/1e3)
  if ($s -lt 60) { return ($s.ToString() + "s") }
  $m = [math]::Floor($s/60); $r = $s % 60
  if ($m -lt 60) { return ($m.ToString() + "m " + $r.ToString() + "s") }
  return ([math]::Floor($m/60)).ToString() + "h " + ($m % 60).ToString() + "m"
}

$script:bootTs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:lastSeenToast = 0

# ── 任务行 ──────────────────────────────────────────────────────────
function Row-Bg([bool]$hover) {
  $top = ($cur.rowTop).Color
  $bot = ($cur.rowBot).Color
  $ta = $top.A; $ba = $bot.A
  if ($hover) { $ta = [math]::Min(255, $ta + 30); $ba = [math]::Min(255, $ba + 22) }
  $topC = [System.Windows.Media.Color]::FromArgb($ta, $top.R, $top.G, $top.B)
  $botC = [System.Windows.Media.Color]::FromArgb($ba, $bot.R, $bot.G, $bot.B)
  return New-Grad @([System.Windows.Media.GradientStop]::new($topC, 0.0), [System.Windows.Media.GradientStop]::new($botC, 1.0))
}

function New-TaskRow($t) {
  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = [System.Windows.CornerRadius]::new(10)
  $b.Margin = [System.Windows.Thickness]::new(0,0,0,6)
  $b.Padding = [System.Windows.Thickness]::new(10,7,10,7)
  $b.Tag = [string]$t.id
  $b.Cursor = "Hand"
  $b.ToolTip = "点击跳转到该会话"
  $b.BorderThickness = [System.Windows.Thickness]::new(1)
  $running = [bool]$t.running
  if ($running) { $b.BorderBrush = ($cur.live) } else { $b.BorderBrush = New-Grad @([System.Windows.Media.GradientStop]::new(($cur.cardRowB).Color, 0.0), [System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb([int]($cur.cardRowB.Color.A * 0.5), ($cur.cardRowB).Color.R, ($cur.cardRowB).Color.G, ($cur.cardRowB).Color.B), 1.0)) }
  $line1 = New-Object System.Windows.Controls.StackPanel
  $line1.Orientation = "Horizontal"
  $dots = @()
  foreach ($di in 0..2) {
    $td = New-Object System.Windows.Controls.TextBlock
    $td.FontSize = 11; $td.VerticalAlignment = "Center"
    $td.Margin = [System.Windows.Thickness]::new(0,0,2,0)
    $td.Foreground = ($cur.accent1)
    $td.Text = $(if ($di -eq 0) { [char]0x25CF } else { [char]0x25CB })
    [void]$line1.Children.Add($td)
    $dots += $td
  }
  if (-not $running) { foreach ($td in $dots) { $td.Visibility = "Collapsed" } }
  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 8; $dot.Height = 8
  $dot.VerticalAlignment = "Center"; $dot.Margin = [System.Windows.Thickness]::new(3,0,9,0)
  $dot.Fill = $cur.idle
  if ($running) { $dot.Visibility = "Collapsed" }
  [void]$line1.Children.Add($dot)

  $title = New-Object System.Windows.Controls.TextBlock
  $title.Text = [string]$t.title; $title.FontSize = 12.5; $title.FontWeight = "Medium"
  $title.Foreground = $cur.text; $title.VerticalAlignment = "Center"
  $title.TextTrimming = "CharacterEllipsis"; $title.MaxWidth = 188
  [void]$line1.Children.Add($title)
  $st = New-Object System.Windows.Controls.TextBlock
  $st.Text = "运行中"; $st.FontSize = 9.5; $st.Foreground = ($cur.live)
  $st.VerticalAlignment = "Center"; $st.Margin = [System.Windows.Thickness]::new(8,0,0,0)
  if (-not $running) { $st.Visibility = "Collapsed" }
  [void]$line1.Children.Add($st)

  $ws = New-Object System.Windows.Controls.TextBlock
  $wsText = [string]$t.workspace
  if ($wsText -and $wsText -ne [string]$t.title) {
    $ws.Text = "工作区 · " + $wsText
    $ws.FontSize = 9.5; $ws.Foreground = $cur.faint; $ws.Margin = [System.Windows.Thickness]::new(0,2,0,0)
    $ws.TextTrimming = "CharacterEllipsis"; $ws.MaxWidth = 200
  } else { $ws.Visibility = "Collapsed" }

  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Orientation = "Vertical"
  [void]$sp.Children.Add($line1)
  if ($ws.Visibility -ne "Collapsed") { [void]$sp.Children.Add($ws) }
  $b.Child = $sp

  $row = @{
    border = $b; dots = $dots; dot = $dot; title = $title; st = $st; ws = $ws;
    running = $running; hovering = $false; runStartTs = 0;
    baseBg = (Row-Bg $false); hoverBg = (Row-Bg $true)
  }
  $b.Background = $row.baseBg
  $b.Add_MouseEnter({ param($s, $e) try { $row.hovering = $true; $s.Background = $row.hoverBg } catch {} })
  $b.Add_MouseLeave({ param($s, $e) try { $row.hovering = $false; $s.Background = $row.baseBg } catch {} })
  return $row
}

# ── 渲染 ────────────────────────────────────────────────────────────
$script:snap = $null
$script:taskRows = @{}   # sessionId -> 行结构（行复用：不重建卡片，动画不被打断）

$script:spinners = @()
$script:spinDriver = $null
function Start-Spin($row) {
  $row.spinIdx = 0
  $script:spinners += $row
  if ($null -eq $script:spinDriver) {
    $script:spinDriver = New-Object System.Windows.Threading.DispatcherTimer
    $script:spinDriver.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:spinDriver.Add_Tick({
      foreach ($r in @($script:spinners)) {
        try {
          $r.spinIdx = ($r.spinIdx + 1) % 3
          for ($di = 0; $di -lt 3; $di++) {
            $r.dots[$di].Text = $(if ($di -eq $r.spinIdx) { [char]0x25CF } else { [char]0x25CB })
          }
        } catch {}
      }
    })
    $script:spinDriver.Start()
  }
}
function Stop-Spin($row) {
  $script:spinners = @($script:spinners | Where-Object { $_ -ne $row })
  if (@($script:spinners).Count -eq 0 -and $null -ne $script:spinDriver) {
    $script:spinDriver.Stop()
    $script:spinDriver = $null
  }
}

# 主题/配置热应用：重绘已有任务行
function Repaint-Rows {
  if ($null -eq $cur) { return }
  foreach ($id in @($script:taskRows.Keys)) {
    try {
      $row = $script:taskRows[$id]
      $row.baseBg = (Row-Bg $false)
      $row.hoverBg = (Row-Bg $true)
      if (-not $row.hovering) { $row.border.Background = $row.baseBg }
      if ($row.running) { $row.border.BorderBrush = ($cur.live) } else { $row.border.BorderBrush = New-Grad @([System.Windows.Media.GradientStop]::new(($cur.cardRowB).Color, 0.0), [System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb([int]($cur.cardRowB.Color.A * 0.5), ($cur.cardRowB).Color.R, ($cur.cardRowB).Color.G, ($cur.cardRowB).Color.B), 1.0)) }
      foreach ($td in $row.dots) { $td.Foreground = ($cur.accent1) }
      $row.dot.Fill = $cur.idle
      $row.title.Foreground = $cur.text
      $row.st.Foreground = ($cur.live)
      $row.ws.Foreground = $cur.faint
    } catch {}
  }
}

function Render-Snapshot {
  $s = $script:snap
  if ($null -eq $s) { return }
  $u.Offline.Visibility = "Collapsed"

  # —— 用量卡：取「最近更新的运行中会话」为主会话；无运行中则取首个含上下文压力的会话 ——
  $src = $null
  foreach ($ss in $s.sessions) {
    if ($ss.running) { if ($null -eq $src -or ($ss.updatedAt -gt $src.updatedAt)) { $src = $ss } }
  }
  if ($null -eq $src) {
    foreach ($ss in $s.sessions) { if ($ss.contextPressure -and $ss.contextPressure.contextWindow) { $src = $ss; break } }
  }
  $pressure = $null; $usage = $null
  if ($null -ne $src) { $pressure = $src.contextPressure; $usage = $src.tokenUsage }
  $used = 0; $cap = 0
  if ($null -ne $pressure) {
    if ($null -ne $pressure.projectedTokens) { $used = [double]$pressure.projectedTokens } else { $used = [double]$pressure.pressureTokens }
    $cap = [double]$pressure.contextWindow
  }
  $tknTotal = 0
  if ($null -ne $usage) {
    $tknTotal = [double]$usage.uncachedInputTokens + [double]$usage.cacheReadTokens + [double]$usage.cacheWriteTokens + [double]$usage.outputTokens
  }
  $balance = $s.balance
  $noKey = $null -ne $balance -and $balance.error -eq 'no-api-key'
  # 本回合 token（主显示）
  $turn = $null
  if ($null -ne $src -and $null -ne $src.turnTokens) { $turn = [double]$src.turnTokens }

  if ($noKey) {
    $u.UHead.Text = "用量 · 未配置 API Key"
    $u.UHead.Foreground = $cur.warn
    $u.USpend.Text = "未配置"; $u.UQuota.Text = "未配置"
    $u.UTknL.Text = if ($turn -gt 0) { "本回合 Token" } else { "Token 用量" }
    $u.UTkn.Text = if ($turn -gt 0) { Fmt-Tokens $turn } elseif ($tknTotal -gt 0) { Fmt-Tokens $tknTotal } else { "—" }
    $u.UTknSub.Text = if ($tknTotal -gt 0) { "累计 " + (Fmt-Tokens $tknTotal) } else { "" }
  } else {
    $u.UHead.Text = "用量"
    $u.UHead.Foreground = $cur.faint
    $u.UTknL.Text = if ($turn -gt 0) { "本回合 Token" } else { "Token 用量" }
    $u.UTkn.Text = if ($turn -gt 0) { Fmt-Tokens $turn } elseif ($tknTotal -gt 0) { Fmt-Tokens $tknTotal } else { "—" }
    $u.UTknSub.Text = if ($tknTotal -gt 0) { "累计 " + (Fmt-Tokens $tknTotal) } else { "" }
    if ($null -ne $balance -and $null -ne $balance.total -and $null -ne $balance.available) {
      $u.USpend.Text = Fmt-Money ([double]$balance.total - [double]$balance.available) ($balance.currency)
    } elseif ($null -ne $balance -and $balance.error -and $balance.error -ne "no-api-key") {
      $u.USpend.Text = "查询失败"
    } else { $u.USpend.Text = "—" }
    if ($cap -gt 0) { $u.URemTkn.Text = Fmt-Tokens ([math]::Max(0, $cap - $used)) } else { $u.URemTkn.Text = "—" }
    if ($null -ne $balance -and $null -ne $balance.available) {
      $u.UQuota.Text = Fmt-Money ([double]$balance.available) ($balance.currency)
    } elseif ($null -ne $balance -and $balance.error -and $balance.error -ne "no-api-key") {
      $u.UQuota.Text = "查询失败"
    } else { $u.UQuota.Text = "—" }
  }
  # 主会话标识
  if ($null -ne $src -and $src.title) {
    $u.USrc.Text = "主会话 · " + [string]$src.title
    $u.USrc.Visibility = "Visible"
  } else { $u.USrc.Visibility = "Collapsed" }

  # —— 主卡：任务列表（行复用）——
  $seen = @{}
  foreach ($ss in $s.sessions) {
    $id = [string]$ss.id
    $running = [bool]$ss.running
    $seen[$id] = $true
    $row = $script:taskRows[$id]
    if ($null -ne $row) {
      $row.title.Text = [string]$ss.title
      if ($ss.workspace -and $ss.workspace -ne [string]$ss.title) {
        $row.ws.Text = "工作区 · " + [string]$ss.workspace; $row.ws.Visibility = "Visible"
      } else { $row.ws.Visibility = "Collapsed" }
      if ($running) {
        if (-not $row.running) {
          foreach ($td in $row.dots) { $td.Visibility = "Visible" }
          $row.dot.Visibility = "Collapsed"; $row.st.Visibility = "Visible"
          $row.border.BorderBrush = ($cur.live)
          $row.runStartTs = if ($ss.updatedAt -gt 0) { $ss.updatedAt } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
          Start-Spin $row
        }
      } else {
        if ($row.running) {
          foreach ($td in $row.dots) { $td.Visibility = "Collapsed" }
          $row.dot.Visibility = "Visible"; $row.st.Visibility = "Collapsed"
          $row.border.BorderBrush = New-Grad @([System.Windows.Media.GradientStop]::new(($cur.cardRowB).Color, 0.0), [System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb([int]($cur.cardRowB.Color.A * 0.5), ($cur.cardRowB).Color.R, ($cur.cardRowB).Color.G, ($cur.cardRowB).Color.B), 1.0))
          Stop-Spin $row
        }
      }
      $row.running = $running
    } else {
      $row = New-TaskRow @{ id = $id; title = [string]$ss.title; workspace = [string]($ss.workspace); running = $running }
      $row.runStartTs = if ($running) { if ($ss.updatedAt -gt 0) { $ss.updatedAt } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } } else { 0 }
      [void]$u.TaskPanel.Children.Add($row.border)
      if ($running) { Start-Spin $row }
      $script:taskRows[$id] = $row
    }
  }
  foreach ($id in @($script:taskRows.Keys)) {
    if (-not $seen.ContainsKey($id)) {
      $gone = $script:taskRows[$id]
      Stop-Spin $gone
      $u.TaskPanel.Children.Remove($gone.border)
      $script:taskRows.Remove($id)
    }
  }
  if ($u.TaskPanel.Children.Count -eq 0) {
    $e = New-Object System.Windows.Controls.TextBlock
    $e.Text = "暂无任务"; $e.FontSize = 11; $e.Foreground = $cur.faint
    $e.HorizontalAlignment = "Center"; $e.Margin = [System.Windows.Thickness]::new(0,14,0,14)
    [void]$u.TaskPanel.Children.Add($e)
  }

  # 运行中任务计时刷新（基于 runStartTs）
  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  foreach ($id in @($script:taskRows.Keys)) {
    try {
      $row = $script:taskRows[$id]
      if ($row.running -and $row.runStartTs -gt 0) {
        $row.st.Text = "运行中 · " + (Fmt-Dur ($nowMs - $row.runStartTs))
      }
    } catch {}
  }

  $now = Get-Date
  $u.FootLeft.Text = "更新于 " + $now.ToString("HH:mm:ss") + " · " + $s.sessions.Count + " 会话"

  # —— 系统通知（替代原窗内 toast）——
  foreach ($ev in $s.events) {
    $ts = [long]$ev.ts
    if ($ts -le $script:lastSeenToast) { continue }
    $script:lastSeenToast = $ts
    if ($ts -le $script:bootTs) { continue }   # 启动前的历史事件不弹，避免一开机刷一堆
    Show-SystemToast ([string]$ev.title) ([string]$ev.detail)
  }
}

# ── 命令文件轮询（宿主控制）────────────────────────────────────────
function Process-Command {
  if (-not (Test-Path $CommandFile)) { return }
  try {
    $cmd = Get-Content $CommandFile -Raw | ConvertFrom-Json
    Remove-Item $CommandFile -Force -ErrorAction SilentlyContinue
  } catch { return }
  $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $script:bootTs
  if ($cmd.action -eq "quit" -and $age -lt 2500) { return }
  switch ($cmd.action) {
    "show" { $win.Show(); $win.Activate() }
    "hide" { $win.Hide() }
    "toggle" { if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() } }
    "config" {
      try {
        if (Test-Path $script:cfgFile) {
          $saved = Get-Content $script:cfgFile -Raw | ConvertFrom-Json
          if ($saved.accent -and $saved.accent -match '^#[0-9A-Fa-f]{6}$') { $script:cfg.accent = $saved.accent }
          if ($null -ne $saved.alpha -and [int]$saved.alpha -ge 40 -and [int]$saved.alpha -le 100) { $script:cfg.alpha = [int]$saved.alpha }
          if ($null -ne $saved.cardAlpha -and [int]$saved.cardAlpha -ge 40 -and [int]$saved.cardAlpha -le 100) { $script:cfg.cardAlpha = [int]$saved.cardAlpha }
          if ($null -ne $saved.locked) { $script:cfg.locked = [bool]$saved.locked }
          if ($saved.preset -and @('topRight','topLeft','bottomRight','bottomLeft') -contains $saved.preset) { $script:cfg.preset = $saved.preset }
          if ($null -ne $saved.usageHidden) { $script:cfg.usageHidden = [bool]$saved.usageHidden }
        }
      } catch {}
      Apply-Theme (Is-LightTheme)
      Apply-Layout
      if ($script:cfg.locked) { $u.LockGlyph.Text = [string][char]0xE72E; $u.LockBtn.ToolTip = '已锁定位置（解锁后可拖动）' } else { $u.LockGlyph.Text = [string][char]0xE785; $u.LockBtn.ToolTip = '锁定位置（锁定后不可拖动）' }
    }
    "quit" { $win.Close() }
  }
}

# ── 系统托盘图标（通知来源 + 退出入口）────────────────────────────
$script:tray = $null
function Ensure-Tray {
  try {
    $bmp = New-Object System.Drawing.Bitmap(16,16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(255,77,159,255))
    $g.FillEllipse([System.Drawing.Brushes]::White, 4,4,8,8)
    $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = $ico
    $ni.Text = "DSH 任务台"
    $ni.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $exitItem = $menu.Items.Add("退出")
    $exitItem.Add_Click({ try { $win.Close() } catch {} })
    $ni.ContextMenuStrip = $menu
    $ni.Add_BalloonTipClicked({ try { $win.Show(); $win.Activate() } catch {} })
    $script:tray = $ni
  } catch {}
}

# ── Windows 系统通知（WinRT Toast，回退托盘气泡）───────────────────
$script:aumid = "DSHTaskWidget.Notification"
$script:toastNotifier = $null

# AUMID 快捷方式：让 WinRT Toast 在 Action Center 正常显示（非打包程序必须）。
$shortcutCode = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("00021401-0000-0000-C000-000000000046"), ClassInterface(ClassInterfaceType.None)]
internal class ShellLink { }

[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IShellLinkW {
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, int fFlags);
    void GetIDList(out IntPtr ppidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
    void GetHotkey(out short pwHotkey);
    void SetHotkey(short wHotkey);
    void GetShowCmd(out int piShowCmd);
    void SetShowCmd(int iShowCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, int dwReserved);
    void Resolve(IntPtr hwnd, int fFlags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPropertyStore {
    void GetCount(out int cProps);
    void GetAt(int iProp, out PropertyKey pkey);
    void GetValue(ref PropertyKey key, out PropVariant pv);
    void SetValue(ref PropertyKey key, ref PropVariant pv);
    void Commit();
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct PropertyKey { public Guid fmtid; public uint pid; }

[StructLayout(LayoutKind.Sequential)]
internal struct PropVariant {
    public ushort vt; public ushort wReserved1; public ushort wReserved2; public ushort wReserved3;
    public IntPtr p; public int p2;
}

[ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPersistFile {
    void GetClassID(out Guid pClassID);
    void IsDirty();
    void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, int dwMode);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
    void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
    void GetCurFile(out string ppszFileName);
}

public class ToastShortcut {
    public static void Ensure(string path, string aumid) {
        if (File.Exists(path)) return;
        IShellLinkW link = (IShellLinkW)new ShellLink();
        link.SetPath(System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName);
        link.SetDescription("DSH 任务台");
        IPropertyStore store = (IPropertyStore)link;
        var key = new PropertyKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
        var pv = new PropVariant { vt = 31 };
        pv.p = Marshal.StringToCoTaskMemUni(aumid);
        store.SetValue(ref key, ref pv);
        store.Commit();
        IPersistFile pf = (IPersistFile)link;
        pf.Save(path, true);
        Marshal.FreeCoTaskMem(pv.p);
    }
}
'@
try { Add-Type -TypeDefinition $shortcutCode -ReferencedAssemblies "System.Windows.Forms" } catch {}

function Ensure-ToastNotifier {
  try {
    Add-Type -AssemblyName Windows.UI.Notifications
    Add-Type -AssemblyName Windows.Data.Xml.Dom
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $startMenu = [System.Environment]::GetFolderPath('StartMenu')
    $lnk = Join-Path $startMenu "Programs\DSH 任务台.lnk"
    if (('ToastShortcut' -as [type]) -ne $null) {
      try { [ToastShortcut]::Ensure($lnk, $script:aumid) } catch {}
    }
    $script:toastNotifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:aumid)
    return $true
  } catch {
    $script:toastNotifier = $null
    return $false
  }
}

function Show-SystemToast([string]$title, [string]$detail) {
  if ($null -eq $script:toastNotifier) { Ensure-ToastNotifier }
  try {
    if ($null -ne $script:toastNotifier) {
      $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
      $safeTitle = [Security.SecurityElement]::Escape($title)
      $safeDetail = [Security.SecurityElement]::Escape($detail)
      $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$safeTitle</text><text>$safeDetail</text></binding></visual></toast>")
      $toast = New-Object Windows.UI.Notifications.ToastNotification($xml)
      Register-ObjectEvent -InputObject $toast -EventName Activated -Action { try { $win.Show(); $win.Activate() } catch {} } | Out-Null
      $script:toastNotifier.Show($toast)
      return
    }
  } catch {}
  # 回退：托盘气泡
  try {
    if ($null -ne $script:tray) {
      $script:tray.ShowBalloonTip(5000, $title, $detail, [System.Windows.Forms.ToolTipIcon]::Info)
    }
  } catch {}
}

# ── 事件处理与接线 ────────────────────────────────────────────────
function OnLock {
  $script:cfg.locked = -not $script:cfg.locked
  if ($script:cfg.locked) { $u.LockGlyph.Text = [string][char]0xE72E } else { $u.LockGlyph.Text = [string][char]0xE785 }
  $u.LockBtn.ToolTip = $(if ($script:cfg.locked) { '已锁定位置（解锁后可拖动）' } else { '锁定位置（锁定后不可拖动）' })
  Save-Cfg
}
$script:dragging = $false
$script:wasDragging = $false
$script:dragStartPos = $null
$script:dragWinPos = $null
$u.Card.Add_PreviewMouseLeftButtonDown({
  param($s, $e)
  $n = $e.OriginalSource
  while ($null -ne $n) {
    if ($n -eq $u.LockBtn) { return }
    $n = [System.Windows.Media.VisualTreeHelper]::GetParent($n)
  }
  if ($script:cfg.locked) { return }
  $script:dragging = $true
  $script:dragStartPos = [System.Windows.Forms.Cursor]::Position
  $script:dragWinPos = @([double]$win.Left, [double]$win.Top)
  $u.Card.CaptureMouse()
  $e.Handled = $true
})
$u.Card.Add_MouseMove({
  param($s, $e)
  if (-not $script:dragging) { return }
  if ($script:cfg.locked) { $script:dragging = $false; $u.Card.ReleaseMouseCapture(); return }
  $p = [System.Windows.Forms.Cursor]::Position
  if ([math]::Abs($p.X - $script:dragStartPos.X) + [math]::Abs($p.Y - $script:dragStartPos.Y) -gt 8) { $script:wasDragging = $true }
  $win.Left = $script:dragWinPos[0] + ($p.X - $script:dragStartPos.X)
  $win.Top = $script:dragWinPos[1] + ($p.Y - $script:dragStartPos.Y)
  $e.Handled = $true
})
$u.Card.Add_MouseLeftButtonUp({
  param($s, $e)
  $script:dragging = $false
  $u.Card.ReleaseMouseCapture()
  if ($script:wasDragging) {
    $script:wasDragging = $false
    # 磁性吸附：松手时若距某角落 ≤48px，自动贴合并记住预设
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $corners = @{
      topLeft    = @($wa.Left + 20, $wa.Top + 20)
      topRight   = @($wa.Right - $win.Width - 20, $wa.Top + 20)
      bottomLeft = @($wa.Left + 20, $wa.Bottom - $win.Height - 20)
      bottomRight= @($wa.Right - $win.Width - 20, $wa.Bottom - $win.Height - 20)
    }
    $best = $null; $bestD = 1e9; $bestKey = $null
    foreach ($k in $corners.Keys) {
      $c = $corners[$k]
      $d = [math]::Abs($c[0]-$win.Left) + [math]::Abs($c[1]-$win.Top)
      if ($d -lt $bestD) { $bestD = $d; $best = $c; $bestKey = $k }
    }
    if ($bestD -le 48) {
      $win.Left = $best[0]; $win.Top = $best[1]
      $script:cfg.preset = $bestKey
      Save-Cfg
    }
    return
  }
  if ($script:cfg.locked) { return }
  $node = $e.OriginalSource
  while ($null -ne $node) {
    if ($node -is [System.Windows.FrameworkElement] -and $null -ne $node.Tag -and $node.Tag -is [string] -and [string]$node.Tag -ne '') { break }
    $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
  }
  if ($null -ne $node -and $null -ne $node.Tag) {
    try { Invoke-RestMethod -Uri ($BaseUrl + "/api/ctl?action=activate&session=" + [Uri]::EscapeDataString([string]$node.Tag)) -Method Post -TimeoutSec 3 | Out-Null } catch {}
  }
})
$u.LockBtn.Add_Click({ OnLock })

# 点击用量卡 → 打开 DSH 用量页（根 UI）
$script:rootUrl = $BaseUrl -replace '/dsh-task-widget$',''
$u.UsageCard.Add_Click({ try { Start-Process $script:rootUrl } catch {} })

# ── 启动 ────────────────────────────────────────────────────────────
$app = New-Object System.Windows.Application
$script:lastLight = $null
$script:hwnd = [IntPtr]::Zero

$null = $win.Add_Loaded({
  $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
  $script:lastLight = $null
  Ensure-Tray
  Apply-Acrylic
  Apply-Theme (Is-LightTheme)
  Apply-Layout
  if ($script:cfg.locked) { $u.LockGlyph.Text = [string][char]0xE72E; $u.LockBtn.ToolTip = '已锁定位置（解锁后可拖动）' } else { $u.LockGlyph.Text = [string][char]0xE785; $u.LockBtn.ToolTip = '锁定位置（锁定后不可拖动）' }
})
$null = $win.Add_LocationChanged({ Apply-RoundCorners })
$null = $win.Add_SizeChanged({ Apply-RoundCorners })

$themeTimer = New-Object System.Windows.Threading.DispatcherTimer
$themeTimer.Interval = [TimeSpan]::FromSeconds(5)
$themeTimer.Add_Tick({
  $light = Is-LightTheme
  if ($light -ne $script:lastLight) {
    $script:lastLight = $light
    Apply-Theme $light
    Apply-RoundCorners
  }
})

$fetchTimer = New-Object System.Windows.Threading.DispatcherTimer
$fetchTimer.Interval = [TimeSpan]::FromSeconds(2)
$fetchTimer.Add_Tick({
  try {
    $r = Invoke-RestMethod -Uri ($BaseUrl + "/api/snapshot") -TimeoutSec 4
    $script:snap = $r
    try { Render-Snapshot } catch {}
  } catch {
    $u.Offline.Visibility = "Visible"
  }
})

$cmdTimer = New-Object System.Windows.Threading.DispatcherTimer
$cmdTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$cmdTimer.Add_Tick({ Process-Command })

# 运行中计时滚动（1s）
$tickTimer = New-Object System.Windows.Threading.DispatcherTimer
$tickTimer.Interval = [TimeSpan]::FromSeconds(1)
$tickTimer.Add_Tick({
  try {
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach ($id in @($script:taskRows.Keys)) {
      $row = $script:taskRows[$id]
      if ($row.running -and $row.runStartTs -gt 0) {
        $row.st.Text = "运行中 · " + (Fmt-Dur ($nowMs - $row.runStartTs))
      }
    }
  } catch {}
})

$null = $win.Add_Closed({
  $fetchTimer.Stop(); $cmdTimer.Stop(); $themeTimer.Stop(); $tickTimer.Stop()
  if ($null -ne $script:tray) { try { $script:tray.Visible = $false; $script:tray.Dispose() } catch {} }
  [System.Windows.Application]::Current.Shutdown()
})

$script:lastLight = (Is-LightTheme)
Apply-Theme $script:lastLight
$themeTimer.Start(); $fetchTimer.Start(); $cmdTimer.Start(); $tickTimer.Start()
$null = $app.Run($win)

# EOF
