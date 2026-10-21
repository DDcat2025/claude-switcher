# Claude 账号切换器 - Windows 界面 (WPF, Beta)
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$BASE = "$env:USERPROFILE\.claude-switcher"
$CORE = "$BASE\claude-switch.ps1"

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude 账号切换器" Width="470" Height="820" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="#FF12141D" Foreground="White">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal" Grid.Row="0" Margin="0,0,0,14">
            <Border Width="44" Height="44" CornerRadius="12">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#FF6366F1" Offset="0"/><GradientStop Color="#FF9333EA" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <TextBlock Text="盾" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="20" Foreground="White"/>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="Claude 账号切换器" FontSize="18" FontWeight="Bold"/>
                <TextBlock Text="安全检查 · 切换 · 启动" FontSize="11" Foreground="#8AFFFFFF"/>
            </StackPanel>
            <Border x:Name="StatusPill" Margin="60,0,0,0" Padding="12,5" CornerRadius="12" Background="#2E22C55E" VerticalAlignment="Center">
                <TextBlock x:Name="StatusText" Text="检查中" FontSize="11" FontWeight="Bold" Foreground="#FFFB923C"/>
            </Border>
        </StackPanel>

        <Border Grid.Row="1" CornerRadius="12" Background="#0DFFFFFF" BorderBrush="#14FFFFFF" BorderThickness="1" Padding="4">
            <ListBox x:Name="CheckList" Background="Transparent" BorderThickness="0" Foreground="#E6FFFFFF" FontSize="13">
                <ListBox.ItemTemplate>
                    <DataTemplate>
                        <Grid Margin="6,6" Width="380">
                            <TextBlock Text="{Binding Name}" VerticalAlignment="Center"/>
                            <TextBlock Text="{Binding Detail}" HorizontalAlignment="Right" Margin="0,0,26,0" Foreground="#73FFFFFF" FontSize="11"/>
                            <TextBlock Text="{Binding Icon}" HorizontalAlignment="Right" Foreground="{Binding Color}" FontSize="14" FontWeight="Bold"/>
                        </Grid>
                    </DataTemplate>
                </ListBox.ItemTemplate>
            </ListBox>
        </Border>

        <StackPanel Grid.Row="2" Margin="0,14,0,0">
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <TextBlock Text="当前账号" FontSize="11" Foreground="#80FFFFFF" VerticalAlignment="Center"/>
                <Border Margin="6,0,0,0" Padding="10,3" CornerRadius="10" Background="#4D6366F1">
                    <TextBlock x:Name="CurrentAccount" Text="?" FontSize="11" FontWeight="Bold" Foreground="#FFA5B4FC"/>
                </Border>
            </StackPanel>
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Button x:Name="BtnA" Grid.Column="0" Content="账号 A" Height="52" FontSize="15" FontWeight="Bold"
                        Foreground="White" Background="#7A6366F1" BorderThickness="0" Cursor="Hand"/>
                <Button x:Name="BtnB" Grid.Column="2" Content="账号 B" Height="52" FontSize="15" FontWeight="Bold"
                        Foreground="White" Background="#14FFFFFF" BorderBrush="#26FFFFFF" Cursor="Hand"/>
            </Grid>
            <TextBlock x:Name="ActionHint" Text="" FontSize="11" Foreground="#80FFFFFF" Margin="0,8,0,0" TextWrapping="Wrap"/>
        </StackPanel>

        <StackPanel Grid.Row="3">
            <TextBlock x:Name="Banner" Text="" FontSize="12" Foreground="#FFF87171" Margin="0,12,0,6" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <Button x:Name="BtnFix" Content="一键修复" Padding="18,8" Margin="0,0,10,0" FontWeight="Bold" Foreground="White" BorderThickness="0" Cursor="Hand">
                    <Button.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                            <GradientStop Color="#FF6366F1" Offset="0"/><GradientStop Color="#FF9333EA" Offset="1"/>
                        </LinearGradientBrush>
                    </Button.Background>
                </Button>
                <Button x:Name="BtnRefresh" Content="重新检查" Padding="18,8" FontWeight="Bold" Foreground="White" Background="#1AFFFFFF" BorderThickness="0" Cursor="Hand"/>
            </StackPanel>
            <TextBlock Text="任何一项检查不过，都不会启动 Claude" FontSize="10" Foreground="#59FFFFFF" HorizontalAlignment="Center" Margin="0,14,0,0"/>
        </StackPanel>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

$rows = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$win.FindName('CheckList').ItemsSource = $rows

$checkNames = @('代理内核','TUN网卡','出口IP','IP一致','时区','地区','IPv6','DNS','WebRTC','保镖','规则置顶','客户端语言','ASN属性','生态可达性')

function Set-Status($text, $color) {
    $win.FindName('StatusText').Text = $text
    $win.FindName('StatusText').Foreground = (New-Object System.Windows.Media.SolidColorBrush $color)
}

function Invoke-Core([string[]]$coreArgs) {
    # checkdetail 改从落盘的 last-check.txt(UTF-8)读取:子进程 stdout 经控制台代码页(如 GBK/936)转码会把中文键名弄乱,导致 14 项只匹配 3 项
    if ($coreArgs[0] -eq 'checkdetail') {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $CORE @coreArgs 2>$null | Out-Null
        return ((Get-Content "$BASE\last-check.txt" -Encoding UTF8) -join "`n").Trim()
    }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $CORE @coreArgs 2>$null
    return ($out | Out-String).Trim()
}

function Refresh-Checks {
    $rows.Clear()
    foreach ($n in $checkNames) { $rows.Add([pscustomobject]@{ Name = $n; Detail = ''; Icon = '…'; Color = '#FF6B7280' }) }
    Set-Status '检查中' ([System.Windows.Media.Color]::FromRgb(0xFB,0x92,0x3C))
    $win.FindName('Banner').Text = ''

    $out = Invoke-Core @('checkdetail')
    $allOk = $true; $matched = 0
    foreach ($line in ($out -split "`n")) {
        $kv = $line -split '=', 2
        if ($kv.Count -ne 2) { continue }
        $st = $kv[1] -split ':', 2
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($rows[$i].Name -eq $kv[0] -or ($kv[0] -eq 'TUN网卡' -and $rows[$i].Name -eq 'TUN网卡')) {
                $matched++
                $d = if ($st.Count -gt 1) { $st[1] } else { '' }
                switch ($st[0]) {
                    'ok'   { $rows[$i] = [pscustomobject]@{ Name = $rows[$i].Name; Detail = $d; Icon = '✓'; Color = '#FF22C55E' } }
                    'warn' { $rows[$i] = [pscustomobject]@{ Name = $rows[$i].Name; Detail = $d; Icon = '⚠'; Color = '#FFFACC15' } }
                    default { $rows[$i] = [pscustomobject]@{ Name = $rows[$i].Name; Detail = $d; Icon = '✗'; Color = '#FFF87171' }; $allOk = $false }
                }
                break
            }
        }
    }
    $st = Invoke-Core @('status')
    $win.FindName('CurrentAccount').Text = if ($st -match 'current=B') { 'B' } elseif ($st -match 'current=A') { 'A' } else { '未初始化' }
    if ($matched -lt $checkNames.Count) {
        Set-Status '检查未过' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
        $win.FindName('Banner').Text = "检测输出不完整($matched/$($checkNames.Count))，请点重新检查"
    } elseif ($allOk) {
        Set-Status '环境安全' ([System.Windows.Media.Color]::FromRgb(0x22,0xC5,0x5E))
    } else {
        Set-Status '检查未过' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
        $win.FindName('Banner').Text = '存在未通过项，可一键修复或手动处理后重试'
    }
}

function Switch-To($t) {
    Set-Status '切换中' ([System.Windows.Media.Color]::FromRgb(0x60,0xA5,0xFA))
    $win.FindName('Banner').Text = "正在切换到账号 $t…（归档约需几十秒）"
    $win.Dispatcher.Invoke([action]{}, 'Render')
    $r = Invoke-Core @('switch', $t)
    if ($r -match '^FAIL:') {
        Set-Status '检查未过' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
        $win.FindName('Banner').Text = $r
    } else {
        $win.FindName('CurrentAccount').Text = $t
        Set-Status '完成' ([System.Windows.Media.Color]::FromRgb(0x22,0xC5,0x5E))
        $win.FindName('Banner').Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x22,0xC5,0x5E)))
        $win.FindName('Banner').Text = "已切换到账号 $t，Claude 启动中。"
    }
}

$win.FindName('BtnRefresh').Add_Click({ Refresh-Checks })
$win.FindName('BtnFix').Add_Click({
    Set-Status '修复中' ([System.Windows.Media.Color]::FromRgb(0xFB,0x92,0x3C))
    $win.FindName('Banner').Text = '正在修复…（会弹出管理员授权框）'
    $win.Dispatcher.Invoke([action]{}, 'Render')
    Invoke-Core @('fix') | Out-Null
    Refresh-Checks
})
$win.FindName('BtnA').Add_Click({ Switch-To 'A' })
$win.FindName('BtnB').Add_Click({ Switch-To 'B' })

$win.Add_ContentRendered({ Refresh-Checks })
[void]$win.ShowDialog()
