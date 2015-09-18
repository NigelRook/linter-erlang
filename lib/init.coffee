{BufferedProcess, CompositeDisposable} = require 'atom'
path = require 'path'
helpers = require('atom-linter')
os = require 'os'
fs = require 'fs'

module.exports =
  config:
    executablePath:
      type: 'string'
      title: 'Erlc Executable Path'
      default: '/usr/local/bin/erlc'
    includeDirs:
      type: 'string'
      title: 'Include dirs'
      description: 'Path to include dirs. Seperated by space.'
      default: './include'
    paPaths:
      type: 'string'
      title: 'pa paths'
      default: "./ebin"
      description: "Paths seperated by space"
    parseRebarConfigs:
      type: 'boolean'
      title: 'Parse Rebar configs'
      default: false
      description: 'Parse rebar configs for pa/include paths'
  activate: ->
    @subscriptions = new CompositeDisposable
    @subscriptions.add atom.config.observe 'linter-erlang.executablePath',
      (executablePath) =>
        @executablePath = executablePath
    @subscriptions.add atom.config.observe 'linter-erlang.includeDirs',
      (includeDirs) =>
        @includeDirs = includeDirs
    @subscriptions.add atom.config.observe 'linter-erlang.paPaths',
      (paPaths) =>
        @paPaths = paPaths
    @subscriptions.add atom.config.observe 'linter-erlang.parseRebarConfigs',
      (parseRebarConfigs) =>
        @parseRebarConfigs = parseRebarConfigs
  deactivate: ->
    @subscriptions.dispose()
  provideLinter: ->
    provider =
      grammarScopes: ['source.erlang']
      scope: 'file' # or 'project'
      lintOnFly: false # must be false for scope: 'project'
      lint: (textEditor) =>
        return new Promise (resolve, reject) =>
          filePath = textEditor.getPath()
          project_path = atom.project.getPaths()
          deps_dir = ""
          project_deps_ebin = ""

          include_dirs = @includeDirs.split(" ")

          if @parseRebarConfigs
            search_dir = path.dirname(filePath)
            additional_include_dirs = []
            until path.relative(project_path.toString(), search_dir) == '..'
              config_file = path.join(search_dir, 'rebar.config')
              if fs.existsSync(config_file)
                rebar_config = fs.readFileSync(config_file)
                if deps_dir == ""
                  re = /{\s*deps_dir\s*,\s*"([^"]*)"\s*}\s*\./
                  match = re.exec(rebar_config)
                  if match && match.length >= 2
                    deps_dir = path.resolve(search_dir, match[1])
                include_dirs.push(path.resolve(search_dir, "./include"))
                re = /{\s*lib_dirs\s*,\s*\[([^\]]*)\]\s*}\s*\./
                match = re.exec(rebar_config)
                if match && match.length >= 2
                  for dir in match[1].split(',')
                    include_dir = dir.replace(/^["\s]*|["\s]*$/g, '')
                    include_dirs.push(path.resolve(search_dir, include_dir))
              search_dir = path.resolve(search_dir, '..')

          if deps_dir == ""
            deps_dir = project_path + "/deps/"

          fs.readdirSync(deps_dir.toString()).filter(
            (item) ->
              project_deps_ebin = deps_dir + item + "/ebin/"
          )

          @paPaths = @paPaths + project_deps_ebin

          compile_result = ""
          erlc_args = ["-Wall"]
          erlc_args.push "-I", dir.trim() for dir in include_dirs
          erlc_args.push "-pa", pa.trim() for pa in @paPaths.split(" ") unless @paPaths == ""
          erlc_args.push "-o", os.tmpDir()
          erlc_args.push filePath

          error_stack = []

          ## This fun will parse the row and split stuff nicely
          parse_row = (row) ->
            if row.indexOf("Module name") != -1
              error_msg = row.split(":")[1]
              linenr = 1
              error_type = "Error"
            else
              row_splittreedA = row.slice(0, row.indexOf(":"))
              re = /[\w\/.]+:(\d+):(.+)/
              re_result = re.exec(row)
              error_type = if re_result? and
                re_result[2].trim().startsWith("Warning") then "Warning" else "Error"
              linenr = parseInt(re_result[1], 10)
              error_msg = re_result[2].trim()
            error_stack.push
              type: error_type
              text: error_msg
              filePath: filePath
              range: helpers.rangeFromLineNumber(textEditor, linenr - 1)
          process = new BufferedProcess
            command: @executablePath
            args: erlc_args
            options:
              cwd: project_path[0] # Should use better folder perhaps
            stdout: (data) ->
              compile_result += data
            exit: (code) ->
              errors = compile_result.split("\n")
              errors.pop()
              parse_row error for error in errors unless !errors?
              resolve error_stack
          process.onWillThrowError ({error,handle}) ->
            atom.notifications.addError "Failed to run #{@executablePath}",
              detail: "#{error.message}"
              dismissable: true
            handle()
            resolve []
