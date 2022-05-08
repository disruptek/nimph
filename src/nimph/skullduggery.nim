#[

yeah, it's a hack and pulls gratuitous symbols into everything.
while we support mainline nim, it's a price i'm willing to pay
for not having to read this crap at the top of every file...

]#

when (compiles do: import compiler/utils/pathutils):
  # nimskull
  import compiler/ast/ast
  import compiler/ast/idents
  import compiler/ast/lineinfos
  import compiler/front/options as compileropts
  import compiler/front/nimconf
  import compiler/front/condsyms
  import compiler/utils/pathutils
else:
  # mainline nim
  import compiler/ast
  import compiler/idents
  import compiler/nimconf
  import compiler/options as compileropts
  import compiler/pathutils
  import compiler/condsyms
  import compiler/lineinfos

export pathutils
export condsyms
export lineinfos
export compileropts
export nimconf
export idents
export ast
