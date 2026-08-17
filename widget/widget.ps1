# dsh-task-widget — Windows 桌面独立小组件（液态玻璃任务台）原生渲染器。
# PowerShell + WPF：无边框、始终置顶、深/浅色跟随系统、任务完成 Windows 系统通知。
#
# v0.6.0 玻璃重做（液态玻璃真模糊）：
#   * 液态玻璃：SetWindowCompositionAttribute(ACCENT_ENABLE_ACRYLICBLURBEHIND=4)（Start 菜单同款），
#     layered 窗口（WPF AllowsTransparency=True → 逐像素透明）同样生效 → 透明 + 真高斯模糊两全，
#     着色(GradientColor ABGR)由我们按 alpha/cardAlpha/主题控制；Win10 1607+ / Win11 通用。
#     ⚠ 走过的弯路：① DWMWA_SYSTEMBACKDROP_TYPE=3 对 layered 窗口静默失效（只剩平涂色）；
#       ② 改 non-layered + Background=Transparent 后部分 WPF/.NET 栈把透明底渲染成纯黑盖住 backdrop。
#   * 透明度语义（F1）：alpha（玻璃透明度）只作用于玻璃层/卡面/高光（Apply-Acrylic 着色 + wash），
#     文字全不透明；cardAlpha 加深玻璃密度；$win.Opacity 恒 1。
#   * 圆角：整窗 CreateRoundRectRgn 区域裁剪（layered 下 DWM 圆角偏好不生效）。
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

# ── 用户配置（软件内调整：强调色 / 玻璃透明度 / 锁定 / 位置 / 用量卡）────────
#   alpha       → 玻璃透明度 40..100（仅玻璃层透明，文字永全不透明；v0.6.0 F1）
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

# Win32 P/Invoke：液态玻璃（Accent）—— SetWindowCompositionAttribute ACCENT_ENABLE_ACRYLICBLURBEHIND。
# 这是 Start 菜单/系统 flyout 同款的合成器级模糊：对 layered 窗口同样生效（WPF AllowsTransparency=True 时
# 逐像素透明 + 真模糊），Win10 1607+ / Win11 全支持；着色 (GradientColor, ABGR) 由我们按 alpha/cardAlpha 控制。
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DshW {
  [StructLayout(LayoutKind.Sequential)]
  public struct AccentPolicy {
    public int AccentState;      // 4 = ACCENT_ENABLE_ACRYLICBLURBEHIND
    public int AccentFlags;      // 0
    public int GradientColor;    // ABGR：alpha<<24 | B<<16 | G<<8 | R
    public int AnimationId;      // 0
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct WindowCompositionAttributeData {
    public int Attribute;        // 19 = WCA_ACCENT_POLICY
    public IntPtr Data;
    public int SizeOfData;
  }
  public static class Accent {
    [DllImport("user32.dll")]
    public static extern bool SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);
  }
}
'@

# Win32 P/Invoke：全屏检测（F4）—— SetWinEventHook 订阅前台/窗口位置事件，回调经 UI 线程消息泵分发
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DshW {
  // 全屏监视回调签名（WINEVENTPROC）
  public delegate void WinEventProcDelegate(int hWinEventHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
  public static class FS {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventProcDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnhookWinEvent(IntPtr hWinEventHook);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, ref RECT lpRect);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  }
}
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

    <!-- 主卡（任务区）：整窗 DWM Acrylic；卡片 = 半透明玻璃贴片，柔和投影托起深度 -->
    <Grid Grid.Row="0">
      <Border x:Name="MainShadow" CornerRadius="22" Background="#0A0F1A" Opacity="0.22" IsHitTestVisible="False">
        <Border.Effect><BlurEffect Radius="20"/></Border.Effect>
      </Border>
      <Border x:Name="Card" CornerRadius="20" BorderThickness="1" ClipToBounds="True" Background="Transparent" Cursor="SizeAll">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="30"/>
          </Grid.RowDefinitions>
          <Border x:Name="SpecGlow" CornerRadius="20" IsHitTestVisible="False" Panel.ZIndex="0"/>
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
      <Border x:Name="UsageShadow" CornerRadius="18" Background="#0A0F1A" Opacity="0.18" IsHitTestVisible="False">
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
  $script:lightTheme = $light
  # F1：玻璃层独立——alpha（玻璃透明度）只作用于玻璃/卡面/高光，文字永全不透明
  $aK = [double]$script:cfg.alpha / 100.0   # 玻璃透明度系数 0.40..1.00（alpha=100 即 v0.5.0 原貌）
  Apply-Acrylic   # 先锁玻璃能力($script:acrylicOn) + 施加 Accent 着色（随 alpha/cardAlpha/主题）
  if ($script:acrylicOn) {
    # 真·液态玻璃：整窗 = Accent 合成器级模糊（layered 逐像素透明，不黑），着色已由 Apply-Acrylic 施加；
    # 卡片 = 半透明玻璃贴片（wash 层），alpha 只加深深浅、动不了文字清晰度（文字全不透明）。
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $tintA = [int][Math]::Round($aK * $p.ck * 40)
    if ($tintA -lt 10) { $tintA = 10 }
    if ($tintA -gt 150) { $tintA = 150 }
    $baseCol = if ($light) { '#FFFFFF' } else { '#0E1320' }
    $cardGlass = New-Brush $baseCol $tintA
    $u.Card.Background = $cardGlass
    $u.UsageCard.Background = $cardGlass
  } else {
    # 降级（无 Accent 支持，如老 Win10）：纯色半透明卡片；卡面透出桌面随 alpha + cardAlpha 变化
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $cardBg = New-Brush $p.surface
    $cardBg.Opacity = $aK * $p.ck
    $u.Card.Background = $cardBg
    $u.UsageCard.Background = $cardBg
  }
  # 顶部高光（光打在玻璃上）—— 高光属玻璃，随 alpha 衰减（baseSheen 已烘焙进渐变停点，乘 aK：alpha=100 即 v0.5.0 原貌）
  $sg = New-Sheen 70; $sg.Opacity = $aK; $u.SpecGlow.Background = $sg
  $ug = New-Sheen 55; $ug.Opacity = $aK; $u.UsageGloss.Background = $ug
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
  # F1：窗口整体不透明度恒为 1（文字/前景永清晰，不随玻璃透明度衰减）
  $win.Opacity = 1.0
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

# ── 圆角：整窗区域裁剪（layered 下 DWM 圆角偏好不生效，全平台统一走 rgn）────
function Apply-RoundCorners {
  if ($script:hwnd -eq [IntPtr]::Zero) { return }
  try {
    # layered 窗口下 DWM 圆角偏好不生效（v0.6.0 重做后窗口本身即玻璃面），全平台走区域裁剪：
    # 圆角=20 裁剪整窗含边距，Accent 模糊随区域裁剪 → 圆角液态玻璃。
    $r = 20
    $hrgn = [DshW.Native]::CreateRoundRectRgn(0, 0, [int]$win.Width, [int]$win.Height, $r, $r)
    [void][DshW.Native]::SetWindowRgn($script:hwnd, $hrgn, $true)
  } catch {}
}

# ── 液态玻璃：Accent 合成器级模糊（Win10 1607+ / Win11）────────────
# SetWindowCompositionAttribute(ACCENT_ENABLE_ACRYLICBLURBEHIND=4)：Start 菜单同款，对 layered 窗口
# （WPF AllowsTransparency=True → 逐像素透明）同样生效 → 透明 + 真高斯模糊两全。
# ⚠ 反过来的坑（v0.6.0 第一次重做踩过）：non-layered + Background=Transparent 在部分 WPF/.NET 栈上
# 会把透明底渲染成纯黑盖住 DWM backdrop，而 DWMWA_SYSTEMBACKDROP_TYPE=3（Acrylic）对 layered 又静默失效
# → 只能走 Accent。着色 GradientColor(ABGR) 随 alpha/cardAlpha/主题，回到 $script:acrylicOn。
function Apply-Acrylic {
  $script:acrylicOn = $false
  if ($script:hwnd -eq [IntPtr]::Zero) { return }
  try {
    $aK = [double]$script:cfg.alpha / 100.0
    $ck = [double]$script:cfg.cardAlpha / 100.0
    $light = if ($null -ne $script:lightTheme) { $script:lightTheme } else { Is-LightTheme }
    if ($light) { $r=255; $g=255; $b=255 } else { $r=0x0E; $g=0x13; $b=0x20 }
    $tintA = [int][Math]::Round($aK * $ck * 150)
    if ($tintA -lt 40) { $tintA = 40 }
    if ($tintA -gt 255) { $tintA = 255 }
    $gradient = (($tintA -shl 24) -bor ($b -shl 16) -bor ($g -shl 8) -bor $r)
    $ap = New-Object DshW.AccentPolicy
    $ap.AccentState = 4; $ap.AccentFlags = 0; $ap.GradientColor = $gradient; $ap.AnimationId = 0
    $wcad = New-Object DshW.WindowCompositionAttributeData
    $wcad.Attribute = 19   # WCA_ACCENT_POLICY
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][DshW.AccentPolicy])
    $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
      [System.Runtime.InteropServices.Marshal]::StructureToPtr($ap, $ptr, $false)
      $wcad.Data = $ptr; $wcad.SizeOfData = $size
      $script:acrylicOn = [DshW.Accent]::SetWindowCompositionAttribute($script:hwnd, [ref]$wcad)
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
  } catch { $script:acrylicOn = $false }
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

# F2 SSE 单通道：后台 runspace 仅入队；UI 线程经 150ms pump 计时器排水（线程安全 ConcurrentQueue）
$script:sseShared = @{ stop = $false; alive = $false }
$script:sseQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:sseRunspace = $null
$script:ssePs = $null
# F3 最近完成可点行池（sessionId -> row；仅渲染已不在 sessions 内的完成会话）
$script:recentRows = @{}
$script:recentHeader = $null
# F4 全屏自动隐藏
$script:fsHooks = @()
$script:winEventProc = $null
$script:winEventHandle = $null
$script:hiddenByFs = $false
# F7 启动诊断日志路径
$script:here = $PSScriptRoot

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
  # F5 任务卡 tooltip：完整 cwd + 父子会话标注
  $tt = [string]$t.cwd
  if ([string]::IsNullOrWhiteSpace($tt)) { $tt = [string]$t.title }
  $parentId = [string]$t.parentId
  if ($parentId) {
    $short = if ($parentId.Length -gt 8) { $parentId.Substring(0,8) } else { $parentId }
    $tt = $tt + "`n↳ 父会话 " + $short
  }
  $b.ToolTip = $tt
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

# F3 最近完成行：已完成的会话（已不在 sessions 内）→ 可点行复用既有 activate 链路
# （行 Tag=sessionId，点击由 Card.MouseLeftButtonUp 的通用上行查找命中并触发 activate）
function New-RecentRow($r) {
  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = [System.Windows.CornerRadius]::new(8)
  $b.Margin = [System.Windows.Thickness]::new(0,0,0,4)
  $b.Padding = [System.Windows.Thickness]::new(10,6,10,6)
  $b.Tag = [string]$r.sessionId
  if (-not [string]$b.Tag) { $b.Tag = [string]$r.id }
  $b.Cursor = "Hand"
  $b.ToolTip = "点击跳转回该会话"
  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Orientation = "Vertical"
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = [string]$r.title; $t.FontSize = 11.5
  $t.TextTrimming = "CharacterEllipsis"; $t.MaxWidth = 196
  $sub = New-Object System.Windows.Controls.TextBlock
  $sub.Text = "✓ 已完成 · " + (Fmt-Ago ([long]$r.doneAt)); $sub.FontSize = 9
  [void]$sp.Children.Add($t); [void]$sp.Children.Add($sub)
  $b.Child = $sp
  $row = @{ border = $b; title = $t; sub = $sub; baseBg = (Row-Bg $false); hoverBg = (Row-Bg $true) }
  $b.Background = $row.baseBg
  $b.Add_MouseEnter({ param($s,$e) try { $s.Background = $row.hoverBg } catch {} })
  $b.Add_MouseLeave({ param($s,$e) try { $s.Background = $row.baseBg } catch {} })
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
  # F3 最近完成行随主题重绘
  foreach ($id in @($script:recentRows.Keys)) {
    try {
      $rr = $script:recentRows[$id]
      $rr.baseBg = (Row-Bg $false)
      $rr.hoverBg = (Row-Bg $true)
      $rr.border.Background = $rr.baseBg
      $rr.title.Foreground = $cur.dim
      $rr.sub.Foreground = $cur.faint
    } catch {}
  }
  if ($null -ne $script:recentHeader) { try { $script:recentHeader.Foreground = $cur.faint } catch {} }
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
  # —— F3 最近完成（可点行 → 既有 activate 链路）——
  $desiredRecent = @()
  if ($s.recentDone -is [array]) {
    foreach ($r in $s.recentDone) {
      if (-not $r -or -not $r.id) { continue }
      $sid = [string]$r.sessionId; if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [string]$r.id }
      if ($script:taskRows.ContainsKey($sid)) { continue }
      if ($seen.ContainsKey($sid)) { continue }
      if ($desiredRecent -contains $sid) { continue }
      $desiredRecent += $sid
      if ($desiredRecent.Count -ge 3) { break }
    }
  }
  if ($u.TaskPanel.Children.Count -eq 0 -and $desiredRecent.Count -eq 0) {
    $e = New-Object System.Windows.Controls.TextBlock
    $e.Text = "暂无任务"; $e.FontSize = 11; $e.Foreground = $cur.faint
    $e.HorizontalAlignment = "Center"; $e.Margin = [System.Windows.Thickness]::new(0,14,0,14)
    [void]$u.TaskPanel.Children.Add($e)
  }
  # 标题「最近完成」
  if ($desiredRecent.Count -gt 0 -and $null -eq $script:recentHeader) {
    $script:recentHeader = New-Object System.Windows.Controls.TextBlock
    $script:recentHeader.Text = "最近完成"
    $script:recentHeader.FontSize = 9.5
    $script:recentHeader.Foreground = $cur.faint
    $script:recentHeader.Margin = [System.Windows.Thickness]::new(2,10,0,2)
    [void]$u.TaskPanel.Children.Add($script:recentHeader)
  } elseif ($desiredRecent.Count -eq 0 -and $null -ne $script:recentHeader) {
    [void]$u.TaskPanel.Children.Remove($script:recentHeader)
    $script:recentHeader = $null
  }
  # 删除不再需要的最近完成行
  foreach ($k in @($script:recentRows.Keys)) {
    if ($desiredRecent -notcontains $k) {
      [void]$u.TaskPanel.Children.Remove($script:recentRows[$k].border)
      $script:recentRows.Remove($k)
    }
  }
  # 添加/更新最近完成行
  foreach ($sid in $desiredRecent) {
    $r = $null
    foreach ($rd in @($s.recentDone)) {
      if (-not $rd) { continue }
      $cand = [string]$rd.sessionId; if ([string]::IsNullOrWhiteSpace($cand)) { $cand = [string]$rd.id }
      if ($cand -eq $sid) { $r = $rd; break }
    }
    if ($null -eq $r) { continue }
    if ($script:recentRows.ContainsKey($sid)) {
      $r0 = $script:recentRows[$sid]
      $r0.title.Text = [string]$r.title
      $r0.sub.Text = "✓ 已完成 · " + (Fmt-Ago ([long]$r.doneAt))
    } else {
      $r0 = New-RecentRow $r
      [void]$u.TaskPanel.Children.Add($r0.border)
      $script:recentRows[$sid] = $r0
    }
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

# ── 命令执行（F2：SSE event:ctl 与 .command.json 文件两路共用此落地函数）──
function Apply-Command-Action([string]$action) {
  switch ($action) {
    "show" { $script:hiddenByFs = $false; $win.Show(); $win.Activate() }
    "hide" { $win.Hide() }
    "toggle" {
      if ($win.IsVisible) { $win.Hide() }
      else { $script:hiddenByFs = $false; $win.Show(); $win.Activate() }
    }
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

# 命令文件轮询（SSE 断连兜底：宿主仍写文件，本路径消费并去重）
function Process-Command {
  if (-not (Test-Path $CommandFile)) { return }
  try {
    $cmd = Get-Content $CommandFile -Raw | ConvertFrom-Json
    Remove-Item $CommandFile -Force -ErrorAction SilentlyContinue
  } catch { return }
  $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $script:bootTs
  if ($cmd.action -eq "quit" -and $age -lt 2500) { return }
  Apply-Command-Action ([string]$cmd.action)
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

# F4 全屏自动隐藏：WinEventHook 回调（UI 线程消息泵分发；仅需 OBJID_WINDOW=0 且属前台窗口的事件）
function Invoke-FsCheck($hWinEventHook, $evt, $hWnd, $idObject, $idChild, $dwEventThread, $dwmsEventTime) {
  try {
    if ([int]$idObject -ne 0) { return }            # 仅窗口本身，忽略子对象/光标等
    if ($hWnd -eq [IntPtr]::Zero) { return }
    $fg = [DshW.FS]::GetForegroundWindow()
    if ($hWnd -ne $fg) { return }                    # 仅响应前台窗口的变化/位置
    $b = New-Object 'DshW.FS+RECT'
    if (-not [DshW.FS]::GetWindowRect($fg, [ref]$b)) { return }
    # 前台窗口所在屏的物理像素边界；rect 充满边界即全屏（容忍 ±4px 抗亚像素/任务栏）
    $scr = [System.Windows.Forms.Screen]::FromHandle($fg)
    if ($null -eq $scr) { return }
    $bounds = $scr.Bounds
    $tol = 4
    $isFs = ($b.Left -le $bounds.Left + $tol) -and ($b.Top -le $bounds.Top + $tol) `
            -and ($b.Right -ge $bounds.Right - $tol) -and ($b.Bottom -ge $bounds.Bottom - $tol)
    if ($isFs -and -not $script:hiddenByFs -and $win.IsVisible) {
      $script:hiddenByFs = $true
      $win.Hide()
    } elseif (-not $isFs -and $script:hiddenByFs) {
      $script:hiddenByFs = $false
      $win.Show(); $win.Activate()
    }
  } catch {}
}

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
# UsageCard 是 Border，无 Click 事件；用 MouseLeftButtonUp 实现点击打开用量页
$u.UsageCard.Add_MouseLeftButtonUp({ try { Start-Process $script:rootUrl } catch {} })

# ── 启动 ────────────────────────────────────────────────────────────
$app = New-Object System.Windows.Application
$script:lastLight = $null
$script:hwnd = [IntPtr]::Zero

$null = $win.Add_Loaded({
  $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
  $script:lastLight = $null
  Ensure-Tray
  Apply-Theme (Is-LightTheme)
  Apply-Layout
  if ($script:cfg.locked) { $u.LockGlyph.Text = [string][char]0xE72E; $u.LockBtn.ToolTip = '已锁定位置（解锁后可拖动）' } else { $u.LockGlyph.Text = [string][char]0xE785; $u.LockBtn.ToolTip = '锁定位置（锁定后不可拖动）' }
  # F4 全屏自动隐藏：注册 WinEventHook（前台切换 + 前台窗口位置变化）
  # WINEVENT_OUTOFCONTEXT=0 → 回调经 UI 线程消息泵分发；委托 GCHandle.Alloc 保活防 GC 回收回调失效
  try {
    $script:winEventProc = [DshW.WinEventProcDelegate]{ param($h,$e,$hWnd,$idObj,$idCh,$t,$ms) Invoke-FsCheck $h $e $hWnd $idObj $idCh $t $ms }
    $script:winEventHandle = [System.Runtime.InteropServices.GCHandle]::Alloc($script:winEventProc)
    # EVENT_SYSTEM_FOREGROUND=0x3, EVENT_OBJECT_LOCATIONCHANGE=0x800B
    $hFg = [DshW.FS]::SetWinEventHook([uint32]0x3, [uint32]0x3, [IntPtr]::Zero, $script:winEventProc, [uint32]0, [uint32]0, [uint32]0x0)
    $hLoc = [DshW.FS]::SetWinEventHook([uint32]0x800B, [uint32]0x800B, [IntPtr]::Zero, $script:winEventProc, [uint32]0, [uint32]0, [uint32]0x0)
    if ($hFg -ne [IntPtr]::Zero) { $script:fsHooks += $hFg }
    if ($hLoc -ne [IntPtr]::Zero) { $script:fsHooks += $hLoc }
  } catch {}
  # F7 启动诊断日志（复盘"为什么没玻璃"等环境态）
  try {
    $themeTag = if (Is-LightTheme) { 'light' } else { 'dark' }
    $line = "[startup] v=0.6.0 win11=$isWin11 acrylic=$($script:acrylicOn) hwnd=$($script:hwnd) theme=$themeTag"
    Add-Content -Path (Join-Path $script:here '.log') -Value $line -Encoding UTF8
  } catch {}
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

# ── F2 SSE 单通道：后台 runspace 长连接解析 event-stream → 入 ConcurrentQueue：UI 线程经 pump 排水 ──
$sseLoop = @'
$ErrorActionPreference = 'Continue'
$backoff = 3000
while (-not $sseShared.stop) {
  $resp = $null; $stream = $null
  try {
    $req = [System.Net.HttpWebRequest]::Create($BaseUrl + "/api/events")
    $req.Method = "GET"
    $req.Accept = "text/event-stream"
    $req.AllowReadStreamBuffering = $false
    $req.KeepAlive = $true
    $req.Timeout = [System.Threading.Timeout]::Infinite
    $req.ReadWriteTimeout = [System.Threading.Timeout]::Infinite
    $resp = $req.GetResponse()
    $stream = $resp.GetResponseStream()
    $sseShared.alive = $true
    $backoff = 3000                       # 连上即重置退避
    $buf = New-Object byte[] 8192
    $sb = New-Object System.Text.StringBuilder
    while (-not $sseShared.stop) {
      $n = 0
      try { $n = $stream.Read($buf, 0, $buf.Length) } catch { $n = 0 }
      if ($n -le 0) { break }
      $chunk = ([System.Text.Encoding]::UTF8.GetString($buf, 0, $n)) -replace "`r",""
      [void]$sb.Append($chunk)
      while ($true) {
        $full = $sb.ToString()
        $idx = $full.IndexOf("`n`n")
        if ($idx -lt 0) { break }
        $frame = $full.Substring(0, $idx)
        $sb.Remove(0, $idx + 2) | Out-Null
        $ev = "message"
        $datab = New-Object System.Text.StringBuilder
        foreach ($ln in ($frame -split "`n")) {
          if ($ln -eq "") { continue }
          if ($ln.StartsWith(":")) { continue }
          if ($ln.StartsWith("event:")) { $ev = $ln.Substring(6).Trim() }
          elseif ($ln.StartsWith("data:")) { [void]$datab.Append($ln.Substring(5).TrimStart()); [void]$datab.Append("`n") }
        }
        $d = $datab.ToString().TrimEnd("`n")
        if ($ev -ne "message" -and $d.Length -gt 0) { [void]$sseQueue.Enqueue($ev + "|" + $d) }
      }
    }
  } catch {} finally {
    try { if ($stream) { $stream.Close() } } catch {}
    try { if ($resp)   { $resp.Close()   } } catch {}
    $sseShared.alive = $false
  }
  if ($sseShared.stop) { break }
  Start-Sleep -Milliseconds $backoff
  if ($backoff -lt 12000) { $backoff = [Math]::Min(12000, $backoff * 2) }
}
'@
try {
  $script:sseRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
  $script:sseRunspace.ApartmentState = "STA"
  $script:sseRunspace.ThreadOptions = "ReuseThread"
  $script:sseRunspace.Open()
  $proxy = $script:sseRunspace.SessionStateProxy
  $proxy.SetVariable('BaseUrl', $BaseUrl)
  $proxy.SetVariable('sseShared', $script:sseShared)
  $proxy.SetVariable('sseQueue', $script:sseQueue)
  $script:ssePs = [System.Management.Automation.PowerShell]::Create()
  $script:ssePs.Runspace = $script:sseRunspace
  [void]$script:ssePs.AddScript($sseLoop)
  $script:sseHandle = $script:ssePs.BeginInvoke()
} catch {
  # SSE 起不来 → 永久走文件轮询兜底（fetchTimer + cmdTimer 已就绪）
}

# UI 线程 SSE 排水泵 + fetchTimer 兜底调度
$ssePumpTimer = New-Object System.Windows.Threading.DispatcherTimer
$ssePumpTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$ssePumpTimer.Add_Tick({
  try {
    $item = $null
    while ($script:sseQueue.TryDequeue([ref]$item)) {
      $sep = $item.IndexOf("|")
      $ev = if ($sep -ge 0) { $item.Substring(0, $sep) } else { "message" }
      $data = if ($sep -ge 0) { $item.Substring($sep + 1) } else { $item }
      switch ($ev) {
        "snapshot" {
          try { $script:snap = $data | ConvertFrom-Json; try { Render-Snapshot } catch {} } catch {}
        }
        "ctl" {
          try { $c = $data | ConvertFrom-Json } catch { $c = $null }
          if ($c -and $c.action) {
            try { Remove-Item $CommandFile -Force -ErrorAction SilentlyContinue } catch {}
            Apply-Command-Action ([string]$c.action)
          }
        }
        default { <# toast 由 snapshot 中的 events 驱动渲染；pending 为 Web 专用，widget 忽略 #> }
      }
    }
    # fetchTimer 兜底：SSE 健康 → 停快照轮询；SSE 断 → 起快照轮询
    if ($script:sseShared.alive) {
      if ($fetchTimer.IsEnabled) { $fetchTimer.Stop() }
    } else {
      if (-not $fetchTimer.IsEnabled) { $fetchTimer.Start() }
    }
  } catch {}
})

$null = $win.Add_Closed({
  $fetchTimer.Stop(); $cmdTimer.Stop(); $themeTimer.Stop(); $tickTimer.Stop()
  try { $ssePumpTimer.Stop() } catch {}
  try { $script:sseShared.stop = $true } catch {}
  try { if ($null -ne $script:ssePs) { $script:ssePs.Stop() } } catch {}
  try { if ($null -ne $script:sseRunspace) { $script:sseRunspace.Close() } } catch {}
  # F4 WinEventHook 卸载 + 释放委托 GC 句柄
  try { foreach ($h in $script:fsHooks) { if ($h -ne [IntPtr]::Zero) { [void][DshW.FS]::UnhookWinEvent($h) } } } catch {}
  $script:fsHooks = @()
  try { if ($script:winEventHandle) { $script:winEventHandle.Free() } } catch {}
  $script:winEventHandle = $null
  if ($null -ne $script:tray) { try { $script:tray.Visible = $false; $script:tray.Dispose() } catch {} }
  [System.Windows.Application]::Current.Shutdown()
})

$script:lastLight = (Is-LightTheme)
Apply-Theme $script:lastLight
$themeTimer.Start(); $fetchTimer.Start(); $cmdTimer.Start(); $tickTimer.Start(); $ssePumpTimer.Start()
$null = $app.Run($win)

# EOF
