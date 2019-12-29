if ( !(Join-Path 'src' 'nimph.nim' | Test-Path) ) {
  git clone git://github.com/disruptek/nimph.git
  Set-Location nimph
} 

$env:NIMBLE_DIR = Join-Path $PWD 'deps'
New-Item -Type Directory $env:NIMBLE_DIR -Force | Out-Null

nimble --accept refresh
nimble install "--passNim:--path:$(Resolve-Path 'src') --outDir:$PWD"
