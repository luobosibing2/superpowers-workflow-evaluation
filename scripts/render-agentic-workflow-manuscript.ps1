[CmdletBinding()]
param(
    [string]$InputPath = (Join-Path $PSScriptRoot '..\reports\agentic-coding-workflows-technical-manuscript.md'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\reports\agentic-coding-workflows-technical-manuscript.html')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$converted = ConvertFrom-Markdown -Path $resolvedInput
$body = [string]$converted.Html

$headingIndex = 0
$subheadingIndex = 0
$navGroups = [ordered]@{
    '摘要' = [Collections.Generic.List[string]]::new()
    '问题与方法' = [Collections.Generic.List[string]]::new()
    '结果' = [Collections.Generic.List[string]]::new()
    '讨论' = [Collections.Generic.List[string]]::new()
    '附录' = [Collections.Generic.List[string]]::new()
}

$body = [regex]::Replace($body, '<h2(?:\s+id="[^"]*")?>(.*?)</h2>', {
    param($match)
    $script:headingIndex++
    $htmlTitle = $match.Groups[1].Value
    $plainTitle = [Net.WebUtility]::HtmlDecode([regex]::Replace($htmlTitle, '<[^>]+>', '')).Trim()
    $id = 'paper-section-{0:d2}' -f $script:headingIndex
    $group = '讨论'

    if ($plainTitle -eq '摘要') {
        $id = 'paper-abstract'
        $group = '摘要'
    } elseif ($plainTitle -match '^(\d+)\.') {
        $sectionNumber = [int]$Matches[1]
        if ($sectionNumber -le 6) {
            $group = '问题与方法'
        } elseif ($sectionNumber -le 10) {
            $group = '结果'
        } else {
            $group = '讨论'
        }
        $id = 'paper-section-{0:d2}' -f $sectionNumber
    } elseif ($plainTitle -match '^附录\s+([A-Z])') {
        $id = 'paper-appendix-{0}' -f $Matches[1].ToLowerInvariant()
        $group = '附录'
    }

    $navGroups[$group].Add("<a href=`"#$id`">$htmlTitle</a>")
    return "<h2 id=`"$id`">$htmlTitle</h2>"
}, [Text.RegularExpressions.RegexOptions]::Singleline)

$body = [regex]::Replace($body, '<h3(?:\s+id="[^"]*")?>(.*?)</h3>', {
    param($match)
    $script:subheadingIndex++
    $id = 'paper-subsection-{0:d3}' -f $script:subheadingIndex
    return "<h3 id=`"$id`">$($match.Groups[1].Value)</h3>"
}, [Text.RegularExpressions.RegexOptions]::Singleline)

$body = [regex]::Replace(
    $body,
    '^\s*(<h1(?:\s+id="[^"]*")?>.*?</h1>)\s*(<blockquote>.*?</blockquote>)',
    '<header class="paper-header">$1<div class="paper-meta">$2</div></header>',
    [Text.RegularExpressions.RegexOptions]::Singleline
)

$body = [regex]::Replace(
    $body,
    '(<h2 id="paper-abstract">.*?</h2>)(.*?)(?=<h2\s+id=)',
    '<section class="abstract" role="doc-abstract" aria-labelledby="paper-abstract">$1$2</section>',
    [Text.RegularExpressions.RegexOptions]::Singleline
)

$figureIndex = 0
$body = [regex]::Replace($body, '<p><img src="([^"]+)" alt="([^"]*)"\s*/?></p>', {
    param($match)
    $script:figureIndex++
    $src = $match.Groups[1].Value
    $alt = $match.Groups[2].Value
    $isTrajectory = $src -match 'superpowers-trajectory'
    $wideClass = if ($isTrajectory) { ' wide trajectory-figure' } else { ' wide' }
    $imageClass = if ($isTrajectory) { 'trajectory-image' } else { 'report-image' }
    $button = ''
    $hint = ''
    if ($isTrajectory) {
        $button = "<button class=`"zoom-button`" type=`"button`" data-src=`"$src`" data-alt=`"$alt`">查看原始尺寸</button>"
        $hint = '<span class="scroll-hint">图面较宽，可横向滚动；每个 cell 使用同一尺度。</span>'
    }
    return "<figure id=`"figure-$($script:figureIndex)`" class=`"figure$wideClass`" aria-labelledby=`"figure-caption-$($script:figureIndex)`"><div class=`"figure-viewport`" tabindex=`"0`" aria-label=`"图 $($script:figureIndex)：$alt`"><img class=`"$imageClass`" src=`"$src`" alt=`"$alt`" loading=`"lazy`"></div><figcaption id=`"figure-caption-$($script:figureIndex)`"><span><b>图 $($script:figureIndex).</b> $alt</span>$hint$button</figcaption></figure>"
}, [Text.RegularExpressions.RegexOptions]::Singleline)

$tableCaptions = @(
    '五种外部能力包的仓库、提交与版本',
    '八个冻结任务、主要难点与诊断面板角色',
    '六种代表配置的八任务连续评分与资源点估计',
    'Superpowers与MatrixSpec L0在连续评分、精确验收和Token上的冲突排序',
    '六种代表配置的逐任务标签盲化评分；每格n=3',
    'Superpowers Full逐任务评分、记录时长、Token、工具调用与hidden-suite结果',
    'CLI任务三种配置的run-level分数与candidate-session Token离散范围',
    '三个补充任务的Superpowers必要性消融；D/E各n=2，B/S各n=3',
    'Targeted review相对brainstorming treatment的观测差异；非配对小样本',
    '四个Superpowers代表session tree的规模与最终验收事实',
    'CLI任务中Terse Bare、Detailed Bare与Forced Superpowers的描述性对照',
    '三个CLI Forced run中协作动作相关ROOT回合用量',
    'MatrixSpec L0与Superpowers Full的逐任务连续评分和已记录Token',
    '六个可对齐任务中MatrixSpec L0与Superpowers的Token构成',
    'MatrixSpec Light/Standard与无/有全量基线的2×2内部结果',
    'Superpowers 14个skills的待验证路由假设；非逐skill实验结论'
)
$tableIndex = 0
$body = [regex]::Replace($body, '<table>(.*?)</table>', {
    param($match)
    $script:tableIndex++
    $tableHtml = $match.Groups[1].Value
    $headers = [regex]::Matches($tableHtml, '<th\b[^>]*>(.*?)</th>', [Text.RegularExpressions.RegexOptions]::Singleline)
    $headerNames = [Collections.Generic.List[string]]::new()
    foreach ($header in $headers) {
        $plainHeader = [Net.WebUtility]::HtmlDecode([regex]::Replace($header.Groups[1].Value, '<[^>]+>', '')).Trim()
        if ($plainHeader) {
            $headerNames.Add($plainHeader)
        }
    }
    $captionParts = @($headerNames | Select-Object -First 3)
    $fallbackCaption = if ($captionParts.Count) { $captionParts -join '、' } else { '正文数据' }
    $captionText = if ($script:tableIndex -le $tableCaptions.Count) { $tableCaptions[$script:tableIndex - 1] } else { $fallbackCaption }
    $columnCount = [Math]::Max(1, $headers.Count)
    $sizeClass = if ($columnCount -ge 7) { 'table-wide' } elseif ($columnCount -ge 4) { 'table-medium' } else { 'table-compact' }
    $tableHtml = [regex]::Replace($tableHtml, '<th\b(?![^>]*\bscope=)([^>]*)>', '<th scope="col"$1>')
    $tableHtml = [regex]::Replace($tableHtml, '<tr>(\s*)<td\b([^>]*)>(.*?)</td>', '<tr>$1<th scope="row"$2>$3</th>', [Text.RegularExpressions.RegexOptions]::Singleline)
    return "<div class=`"table-wrap $sizeClass`" tabindex=`"0`" aria-label=`"表 $($script:tableIndex)：$captionText`"><table><caption><b>表 $($script:tableIndex).</b> $captionText</caption>$tableHtml</table></div>"
}, [Text.RegularExpressions.RegexOptions]::Singleline)

$navSections = [Collections.Generic.List[string]]::new()
foreach ($group in $navGroups.Keys) {
    if ($navGroups[$group].Count -eq 0) {
        continue
    }
    $items = $navGroups[$group] -join "`n"
    $navSections.Add("<div class=`"toc-group`"><div class=`"toc-label`">$group</div>$items</div>")
}
$nav = $navSections -join "`n"

$style = @'
:root{--ink:#18212a;--muted:#5b6670;--paper:#ffffff;--page:#f4f5f6;--line:#d9dde1;--soft:#f6f7f8;--accent:#245f8f;--accent-dark:#17486e;--code:#f0f2f4;--prose:46rem;--wide:78rem}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--page);color:var(--ink);font:16px/1.72 Inter,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}a{color:var(--accent);text-underline-offset:3px}a:focus-visible,button:focus-visible,[tabindex="0"]:focus-visible{outline:3px solid #7bb4df;outline-offset:3px}.skip-link{position:absolute;left:-9999px;top:8px;z-index:20;background:#fff;border:2px solid var(--accent);padding:8px 12px}.skip-link:focus{left:8px}.layout{display:grid;grid-template-columns:250px minmax(0,1fr);max-width:1600px;margin:auto;background:var(--paper);min-height:100vh}.sidebar{position:sticky;top:0;height:100vh;border-right:1px solid var(--line);padding:28px 20px;overflow:auto;background:#fafafa}.brand{font:700 16px/1.35 Georgia,"Times New Roman","Songti SC",serif}.stamp{font-size:12px;line-height:1.55;color:var(--muted);margin:9px 0 24px}.toc summary{display:none}.toc-group{margin:0 0 18px}.toc-label{font-size:11px;font-weight:750;letter-spacing:.08em;color:#76818a;margin:0 8px 5px;text-transform:uppercase}.toc a{display:block;text-decoration:none;color:#4c5862;padding:5px 8px;border-left:2px solid transparent;font-size:12.5px;line-height:1.35}.toc a:hover,.toc a.active{border-left-color:var(--accent);color:var(--accent-dark);background:#eef4f8}.page{min-width:0;padding:0 50px 84px}.paper{margin:0}.paper-header,.paper>p,.paper>ul,.paper>ol,.paper>pre,.paper>blockquote,.paper>h2,.paper>h3,.paper>h4,.paper>.abstract,.paper>.table-wrap:not(.table-wide),.paper>.figure:not(.wide){max-width:var(--prose);margin-left:auto;margin-right:auto}.paper-header{padding:64px 0 26px;border-bottom:1px solid var(--ink)}h1{font:700 clamp(36px,4.5vw,48px)/1.16 Georgia,"Times New Roman","Songti SC",serif;letter-spacing:-.015em;margin:0 0 22px}.paper-meta blockquote{margin:0;padding:0;border:0;background:transparent;color:var(--muted);font-size:14px;font-weight:400}.paper-meta blockquote p{margin:0}.abstract{padding:24px 0 26px;border-bottom:1px solid var(--ink)}.abstract h2{border:0;margin:0 0 10px;padding:0;font:700 20px/1.35 Georgia,"Times New Roman","Songti SC",serif}.abstract p{margin:0 0 11px;font-size:15px;line-height:1.68}.abstract p:last-child{margin-bottom:0}h2{font:700 29px/1.3 Georgia,"Times New Roman","Songti SC",serif;letter-spacing:-.01em;margin-top:60px!important;margin-bottom:18px!important;padding-top:17px;border-top:1px solid var(--line);scroll-margin-top:20px}h3{font:700 21px/1.4 Georgia,"Times New Roman","Songti SC",serif;margin-top:36px!important;margin-bottom:11px!important}h4{font-size:17px;margin-top:28px!important;margin-bottom:9px!important}p{margin-top:0;margin-bottom:16px}ul,ol{padding-left:1.45rem}li{margin-bottom:6px}blockquote{padding:13px 18px;border-left:3px solid var(--accent);background:var(--soft);font-size:17px;margin-top:22px!important;margin-bottom:22px!important}code{font-family:"Cascadia Code",Consolas,monospace;background:var(--code);padding:.1rem .3rem;border-radius:3px;font-size:.9em}pre{background:#1e2832;color:#edf1f4;border-radius:4px;padding:17px;overflow:auto;font:13px/1.58 "Cascadia Code",Consolas,monospace}pre code{background:transparent;padding:0}.table-wrap{overflow:auto;margin:21px auto 30px;border-top:1px solid #89939b;border-bottom:1px solid #89939b}.table-medium{max-width:62rem}.table-wide{max-width:var(--wide)}table{width:100%;border-collapse:collapse;font-size:13px;line-height:1.45;min-width:620px;font-variant-numeric:tabular-nums}caption{text-align:left;padding:8px 2px 9px;color:#3c4852;font-size:13px}th,td{padding:8px 9px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}th{background:#f1f3f5;font-size:12px;font-weight:700;position:sticky;top:0;z-index:1}th:first-child,td:first-child{position:sticky;left:0;background:var(--paper);z-index:2}thead th:first-child{background:#f1f3f5;z-index:3}tr:last-child td{border-bottom:0}.figure{margin:27px auto 38px;max-width:var(--prose)}.figure.wide{max-width:var(--wide)}.figure-viewport{overflow:auto;border:1px solid var(--line);background:#fff;padding:8px}.report-image{display:block;width:100%;height:auto}.trajectory-image{display:block;width:max(100%,1450px);height:auto}figcaption{display:flex;align-items:flex-start;gap:12px;flex-wrap:wrap;font-size:13px;line-height:1.5;color:var(--muted);padding:9px 2px 0}.scroll-hint{font-style:italic}.zoom-button{margin-left:auto;border:1px solid #9aa5ad;background:#fff;color:var(--accent-dark);border-radius:3px;padding:5px 9px;cursor:pointer}.footer{max-width:var(--prose);margin:66px auto 0;border-top:1px solid var(--line);padding-top:17px;color:var(--muted);font-size:12px}dialog{border:0;border-radius:4px;padding:0;max-width:98vw;max-height:96vh}dialog::backdrop{background:#111b}.zoomhead{position:sticky;left:0;display:flex;justify-content:space-between;align-items:center;padding:10px 14px;border-bottom:1px solid var(--line);background:white}.zoomhead button{border:1px solid var(--line);background:#fff;padding:6px 10px;cursor:pointer}dialog img{display:block;width:auto;height:auto;max-width:none}.zoom-scroll{overflow:auto;max-width:97vw;max-height:88vh}
@media(max-width:980px){.layout{display:block}.sidebar{position:relative;height:auto;border-right:0;border-bottom:1px solid var(--line);padding:16px 20px}.brand,.stamp{display:inline-block;margin:0 14px 0 0}.toc summary{display:block;cursor:pointer;font-weight:700;margin-top:12px}.toc nav{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-top:12px}.toc-group{margin:0}.page{padding:0 24px 68px}.paper-header{padding-top:44px}}
@media(max-width:620px){.page{padding-left:17px;padding-right:17px}.toc nav{grid-template-columns:1fr}h1{font-size:34px}h2{font-size:25px}blockquote{font-size:16px}.table-wrap,.figure.wide{width:calc(100vw - 34px)}figcaption{display:block}.zoom-button{margin:8px 0 0}}
@page{size:A4;margin:16mm 15mm}@page trajectory{size:A4 landscape;margin:10mm}@media print{body{background:#fff;font-size:10.5pt;line-height:1.55}.sidebar,.skip-link,.zoom-button,.scroll-hint,dialog{display:none!important}.layout{display:block;max-width:none}.page{padding:0}.paper-header{padding-top:0}.paper-header,.paper>p,.paper>ul,.paper>ol,.paper>pre,.paper>blockquote,.paper>h2,.paper>h3,.paper>h4,.paper>.abstract,.paper>.table-wrap,.paper>.figure,.footer{max-width:none}.table-wrap,.figure,.abstract,pre,blockquote{break-inside:avoid}.trajectory-figure{page:trajectory;break-before:page;break-after:page}.table-wrap{overflow:visible}table{min-width:0;font-size:8pt}thead{display:table-header-group}tr{break-inside:avoid}th:first-child,td:first-child,th{position:static}.trajectory-image,.report-image{width:100%;min-width:0}.figure-viewport{overflow:visible;border-color:#999}a{color:inherit;text-decoration:none}h2{break-after:avoid;margin-top:28px!important}.footer{display:none}}
'@

$document = @"
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="八任务工作流评测、Superpowers消融、Return-aware轨迹与Token成本分析。">
<title>Agentic Coding 工作流的质量、成本与轨迹</title>
<style>$style</style>
</head>
<body>
<a class="skip-link" href="#main-content">跳到正文</a>
<div class="layout">
<aside class="sidebar" aria-label="论文目录">
  <div class="brand">Agentic Coding 工作流研究</div>
  <div class="stamp">中文技术母稿 v0.2 · 2026-07-28</div>
  <details class="toc" open>
    <summary>目录</summary>
    <nav id="nav" aria-label="章节目录">$nav</nav>
  </details>
</aside>
<main id="main-content" class="page">
<article class="paper">
$body
</article>
<footer class="footer">由 <code>scripts/render-agentic-workflow-manuscript.ps1</code> 从同名 Markdown 生成。冻结 campaign evidence 未被修改。</footer>
</main>
</div>
<dialog id="zoom" aria-labelledby="zoom-title">
  <div class="zoomhead"><b id="zoom-title">Trajectory</b><button id="zoom-close" type="button">关闭</button></div>
  <div class="zoom-scroll"><img id="zoom-image" alt=""></div>
</dialog>
<script>
const links=[...document.querySelectorAll('#nav a')],sections=[...document.querySelectorAll('article h2[id]')];
const toc=document.querySelector('.toc');if(window.matchMedia('(max-width:980px)').matches)toc.removeAttribute('open');
const observer=new IntersectionObserver(entries=>entries.forEach(entry=>{if(entry.isIntersecting)links.forEach(a=>{const active=a.hash==='#'+entry.target.id;a.classList.toggle('active',active);if(active)a.setAttribute('aria-current','location');else a.removeAttribute('aria-current')})}),{rootMargin:'-14% 0px -76%'});
sections.forEach(section=>observer.observe(section));
const dialog=document.getElementById('zoom'),zoomImage=document.getElementById('zoom-image'),zoomTitle=document.getElementById('zoom-title');
document.querySelectorAll('.zoom-button').forEach(button=>button.addEventListener('click',()=>{zoomImage.src=button.dataset.src;zoomImage.alt=button.dataset.alt;zoomTitle.textContent=button.dataset.alt;dialog.showModal()}));
document.getElementById('zoom-close').addEventListener('click',()=>dialog.close());
dialog.addEventListener('click',event=>{if(event.target===dialog)dialog.close()});
</script>
</body>
</html>
"@

[IO.File]::WriteAllText($resolvedOutput, $document, [Text.UTF8Encoding]::new($false))
Write-Output $resolvedOutput
