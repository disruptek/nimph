#[

yeah, it's a hack and pulls gratuitous symbols into everything.
while we support mainline nim, it's a price i'm willing to pay
for not having to read this crap at the top of every file...

]#

when defined(isNimSkull):
  # nimskull
  import compiler/ast/ast
  import compiler/ast/idents
  import compiler/ast/lineinfos
  import compiler/front/options as compileropts
  import compiler/front/nimconf
  import compiler/front/condsyms
  import compiler/utils/pathutils
  from compiler/front/cli_reporter import reportHook
  from compiler/ast/report_enums import ReportKind

  const
    isNimskull = true
    hintConf = report_enums.ReportKind.rextConf
    hintLineTooLong = report_enums.ReportKind.rlexLineTooLong

  proc newConfigRef(): ConfigRef =
    compileropts.newConfigRef(cli_reporter.reportHook)
else:
  # mainline nim
  import compiler/ast
  import compiler/idents
  import compiler/nimconf
  import compiler/options as compileropts
  import compiler/pathutils
  import compiler/condsyms
  import compiler/lineinfos

  const isNimskull = false