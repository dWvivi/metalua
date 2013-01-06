--*-lua-*-

-- Main file for the metalua executable
require 'metalua.package2'
require 'metalua.compiler.globals'
local compiler = require 'metalua.compiler.convert'
local clopts   = require 'metalua.clopts'

AST_COMPILE_ERROR_NUMBER        = -1
RUNTIME_ERROR_NUMBER            = -3
BYTECODE_SYNTHESE_ERROR_NUMBER  = -100

local chunks  = { }
local runargs = { }

local function acc_chunk(kind)
    return function(x)
        table.insert (chunks, { tag=kind, x })
    end
end

parser = clopts {
   -- Chunk loading
   {  short = 'f', long = 'file', type = 'string', action = acc_chunk 'File',
      usage = 'load a file to compile and/or run'
   },
   {  short = 'l', long = 'library', type = 'string', action = acc_chunk 'Library',
      usage = 'load a libary from the standard paths'
   },
   {  short = 'e', long = 'literal', type = 'string', action = acc_chunk 'Literal',
      usage = 'load a literal piece of source code'
   },
   -- What to do with chunks
   {  short = 'o', long = 'output', type = 'string',
      usage = 'set the target name of the next compiled file'
   },
   {  short = 'x', long = 'run', type = 'boolean',
      usage = 'execute the compiled file instead of saving it (unless -o is also used)'
   },
   {  short = 'i', long = 'interactive', type = 'boolean',
      usage = 'run an interactive loop after having run other files'
   },
   -- Advanced stuff
   {  short = 'v', long = 'verbose', type = 'boolean',
      usage = 'verbose mode'
   },
   {  short = 'a', long = 'print-ast',  type = 'boolean',
      usage = 'print the AST resulting from file compilation'
   },
   {  short = 'A', long = 'print-ast-lineinfo',  type = 'boolean',
      usage = 'print the AST resulting from file compilation, including lineinfo data'
   },
   {  short = 'S', long = 'print-src',  type = 'boolean',
      usage = 'print the AST resulting from file compilation, as re-gerenerated sources'
   },
   {  short = 'b', long = 'metabugs', type = 'boolean',
      usage = 'show syntax errors as compile-time execution errors'
   },
   {  short = 's', long = 'sharpbang', type = 'string',
      usage = 'set a first line to add to compiled file, typically "#!/bin/env mlr"'
   },
   {  long  = 'no-runtime', type = 'boolean',
      usage = "prevent the automatic requirement of metalua runtime"
   },
   {  long  = '', short = 'p', type = '*',
      action= function (newargs) runargs=table.icat(runargs, newargs) end,
      usage = "pass all remaining arguments to the program"
   },

usage=[[

Compile and/or execute metalua programs. Parameters passed to the
compiler should be prefixed with an option flag, hinting what must be
done with them: take tham as file names to compile, as library names
to load, as parameters passed to the running program... When option
flags are absent, metalua tries to adopt a "Do What I Mean" approach:

- if no code (no library, no literal expression and no file) is
  specified, the first flag-less parameter is taken as a file name to
  load.

- if no code and no parameter is passed, an interactive loop is
  started.

- if a target file is specified with --output, the program is not
  executed by default, unless a --run flag forces it to. Conversely,
  if no --output target is specified, the code is run unless ++run
  forbids it.
]]}

local function main (...)

   local cfg = parser(...)

   -------------------------------------------------------------------
   -- Print messages if in verbose mode
   -------------------------------------------------------------------
   local function verb_print (fmt, ...)
      if cfg.verbose then
         return printf ("[ "..fmt.." ]", ...)
      end
   end

   if cfg.verbose then
      verb_print("raw options: %s", table.tostring(cfg))
   end

   -------------------------------------------------------------------
   -- If there's no chunk but there are params, interpret the first
   -- param as a file name.
   if #chunks==0 and cfg.params then
      local the_file = table.remove(cfg.params, 1)
      verb_print("Param %q considered as a source file", the_file)
      chunks = { {tag='File', the_file } }
   end

   -------------------------------------------------------------------
   -- If nothing to do, run REPL loop
   if #chunks==0 and cfg.interactive==nil then
      verb_print "Nothing to compile nor run, force interactive loop"
      cfg.interactive=true
   end


   -------------------------------------------------------------------
   -- Run if asked to, or if no --output has been given
   -- if cfg.run==false it's been *forced* to false, don't override.
   if cfg.run==nil and not cfg.output then
      verb_print("No output file specified; I'll run the program")
      cfg.run = true
   end

   local code = { }

   -------------------------------------------------------------------
   -- Get ASTs from sources

   local last_file
   for x in values(chunks) do
      local tag, val = x.tag, x[1]
      verb_print("Compiling %s", table.tostring(x))
      local st, ast
      if tag=='Library' then
          ast = { tag='Call',
                  {tag='Id', "require" },
                  {tag='String', val } }
      elseif tag=='Literal' then ast = compiler.luastring_to_ast(val)
      elseif tag=='File' then
         ast = compiler.luafile_to_ast(val)
         -- Isolate each file in a separate fenv
         ast = {tag='Function', {tag='Dots'}, ast }
         ast.source  = '@'..val -- TODO [EVE]
         code.source = '@'..val -- TODO [EVE]
         last_file = ast
      else
          error ("Bad option "..tag)
      end
      local valid = true -- TODO: check AST's correctness
      if not valid then
         printf ("Cannot compile %s:\n%s", table.tostring(x), ast or "no msg")
         os.exit (AST_COMPILE_ERROR_NUMBER)
      end
      ast.origin = x
      table.insert(code, ast)
   end
   -- The last file returns the whole chunk's result
   if last_file then
      local c = table.shallow_copy(last_file)
      last_file.tag='Return'
      last_file.source = c.source
      last_file[1] = c
   end

   -------------------------------------------------------------------
   -- AST printing
   if cfg['print-ast'] or cfg['print-ast-lineinfo'] then
      verb_print "Resulting AST:"
      for x in ivalues(code) do
         printf("--- AST From %s: ---", table.tostring(x.source, 'nohash'))
         if x.origin and x.origin.tag=='File' then x=x[1][1][2][1] end
         if cfg['print-ast-lineinfo'] then table.print(x, 80, "indent1")
         else table.print(x, 80, 'nohash') end
      end
   end

   -------------------------------------------------------------------
   -- Source printing
   if cfg['print-src'] then
      verb_print "Resulting sources:"
      require 'metalua.ast_to_string'
      for x in ivalues(code) do
         printf("--- Source From %s: ---", table.tostring(x.source, 'nohash'))
         if x.origin and x.origin.tag=='File' then x=x[1][1][2][1] end
         print (ast_to_string (x))
      end
   end

   -- FIXME: canonize/check AST

   -------------------------------------------------------------------
   -- Insert runtime loader
   if cfg['no-runtime'] then
      verb_print "Prevent insertion of command \"require 'metalua.runtime'\""
   else
       local req_runtime = { tag='Call',
                             {tag='Id', "require"},
                             {tag='String', "metalua.runtime"} }
       table.insert(code, 1, req_runtime)
   end

   local bytecode = compiler.ast_to_luacstring (code)
   code = nil

   -------------------------------------------------------------------
   -- Insert #!... command
   if cfg.sharpbang then
      local shbang = cfg.sharpbang
      verb_print ("Adding sharp-bang directive %q", shbang)
      if not shbang :match'^#!' then shbang = '#!' .. shbang end
      if not shbang :match'\n$' then shbang = shbang .. '\n' end
      bytecode = shbang .. bytecode
   end

   -------------------------------------------------------------------
   -- Save to file
   if cfg.output then
      -- FIXME: handle '-'
      verb_print ("Saving to file %q", cfg.output)
      local file, err_msg = io.open(cfg.output, 'wb')
      if not file then error("can't open output file: "..err_msg) end
      file:write(bytecode)
      file:close()
      if cfg.sharpbang and os.getenv "OS" ~= "Windows_NT" then
         pcall(os.execute, 'chmod a+x "'..cfg.output..'"')
      end
   end

   -------------------------------------------------------------------
   -- Run compiled code
   if cfg.run then
      verb_print "Running"
      local f = compiler.luacstring_to_function (bytecode)
      bytecode = nil
      -- FIXME: isolate execution in a ring
      -- FIXME: check for failures
      runargs = table.icat(cfg.params or { }, runargs)
      local function print_traceback (errmsg)
         return errmsg .. '\n' .. debug.traceback ('',2) .. '\n'
      end
      local function g() return f(unpack (runargs)) end
      local st, msg = xpcall(g, print_traceback)
      if not st then
         io.stderr:write(msg)
         os.exit(RUNTIME_ERROR_NUMBER)
      end
   end

   -------------------------------------------------------------------
   -- Run REPL loop
   if cfg.interactive then
      verb_print "Starting REPL loop"
      require 'metalua.repl' .run()
   end

   verb_print "Done"

end

if debug.getinfo(1).what=='main' then main(...)
else return main end