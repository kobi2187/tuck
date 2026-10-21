## Weekend programs, the kind a Python or Ruby user writes on day one: built
## against `--stdlib:stdlib-project` and RUN on Nim, Odin and D with fixed
## arguments and stdin, their stdout and exit code compared exactly.
##
## Each program lives in `stdlib-project/apps/<dir>/`. A case is one run; a
## program is built once per backend and every case of it runs against that
## build. Programs that use randomness take `--seed N`, so a run replays.

import std/[os, strutils]
import ../harness

type AppCase = tuple
  dir, file, args, input, want: string
  code: int

const JsonDoc = "{\"name\": \"weekend\", \"tags\": [\"tuck\", \"json\"], \"users\": [\n" &
   "  {\"name\": \"ada\", \"age\": 36, \"score\": 9.5, \"admin\": true},\n" &
   "  {\"name\": \"bob\", \"age\": 41, \"score\": -2, \"admin\": false, \"note\": null}\n" &
   "], \"empty\": {}, \"none\": []}\n"

const CsvDoc = "city,population,area,country\n" &
   "Oslo,709037,454.0,Norway\n" &
   "Bergen,291940,465.3,Norway\n" &
   "Lyon,522250,47.87,France\n" &
   "Nice,,71.92,France\n" &
   "Porto,231800,41.42,Portugal\n"

const SpellText = "The quik brown fox jumps ovar the lazi dog.\n" &
   "Don't worry: this checker can't know every word.\n" &
   "Hello, wrold!\n"

const Cases: seq[AppCase] = @[
  ("cli-hangman", "hangman", "--seed 2", "t\nu\nz\nc\nk\n",
   "Word: ____   Lives: 6\nWord: t___   Lives: 6\nWord: tu__   Lives: 6\n" &
   "Word: tu__   Lives: 5\nWord: tuc_   Lives: 5\nWord: tuck   Lives: 5\nYou win!\n", 0),
  ("cli-hangman", "hangman", "--seed 2", "a\nb\nd\nf\ng\nh\n",
   "Word: ____   Lives: 6\nWord: ____   Lives: 5\nWord: ____   Lives: 4\n" &
   "Word: ____   Lives: 3\nWord: ____   Lives: 2\nWord: ____   Lives: 1\n" &
   "Word: ____   Lives: 0\nYou lose. The word was: tuck\n", 1),
  # no newline after the last guess: still a line (A86)
  ("cli-hangman", "hangman", "--seed 2", "t\nu\nc\nk",
   "Word: ____   Lives: 6\nWord: t___   Lives: 6\nWord: tu__   Lives: 6\n" &
   "Word: tuc_   Lives: 6\nWord: tuck   Lives: 6\nYou win!\n", 0),
  ("passgen", "passgen", "--length 12 --count 3 --seed 7", "",
   "MkX&E4243bQs\n5HEDu=w_IN52\n#^q!DV57c%%B\n", 0),
  ("passgen", "passgen", "--length 3", "",
   "passgen: --length must be at least 4\n", 2),
  # a word that is not a number costs no try
  ("guess", "guess", "--seed 3", "50\n75\nx\n94\n",
   "I'm thinking of a number from 1 to 100.\nHigher.\nHigher.\n" &
   "That is not a number: x\nGot it in 3 tries!\n", 0),
  ("guess", "guess", "--seed 3", "10\n",
   "I'm thinking of a number from 1 to 100.\nHigher.\nThe number was 94.\n", 1),
  # headings, inline marks, both list kinds, a fence; HTML escaped
  ("md2html", "md2html", "",
   "# Weekend notes\n" &
   "\n" &
   "Tuck is *small* and **fast**, with `code` and a [link](https://example.com/?a=1&b=2).\n" &
   "\n" &
   "- one\n" &
   "- two with <angle> brackets\n" &
   "\n" &
   "1. first\n" &
   "2. second\n" &
   "\n" &
   "```\n" &
   "let x = 1 < 2\n" &
   "```\n",
   "<h1>Weekend notes</h1>\n" &
   "<p>\n" &
   "Tuck is <em>small</em> and <strong>fast</strong>, with <code>code</code> and a <a href=\"https://example.com/?a=1&amp;b=2\">link</a>.\n" &
   "</p>\n" &
   "<ul>\n" &
   "<li>one</li>\n" &
   "<li>two with &lt;angle&gt; brackets</li>\n" &
   "</ul>\n" &
   "<ol>\n" &
   "<li>first</li>\n" &
   "<li>second</li>\n" &
   "</ol>\n" &
   "<pre><code>\n" &
   "let x = 1 &lt; 2\n" &
   "</code></pre>\n", 0),
  # the whole document, indented; integral numbers print without a fraction
  ("jsonq", "jsonq", "", JsonDoc,
   "{\n" &
   "  \"name\": \"weekend\",\n" &
   "  \"tags\": [\n" &
   "    \"tuck\",\n" &
   "    \"json\"\n" &
   "  ],\n" &
   "  \"users\": [\n" &
   "    {\n" &
   "      \"name\": \"ada\",\n" &
   "      \"age\": 36,\n" &
   "      \"score\": 9.5,\n" &
   "      \"admin\": true\n" &
   "    },\n" &
   "    {\n" &
   "      \"name\": \"bob\",\n" &
   "      \"age\": 41,\n" &
   "      \"score\": -2,\n" &
   "      \"admin\": false,\n" &
   "      \"note\": null\n" &
   "    }\n" &
   "  ],\n" &
   "  \"empty\": {},\n" &
   "  \"none\": []\n" &
   "}\n", 0),
  ("jsonq", "jsonq", ".users[1].name --raw", JsonDoc, "bob\n", 0),
  ("jsonq", "jsonq", ".users[0] --compact", JsonDoc,
   "{\"name\":\"ada\",\"age\":36,\"score\":9.5,\"admin\":true}\n", 0),
  ("jsonq", "jsonq", ".tags[5]", JsonDoc, "jsonq: nothing at .tags[5]\n", 1),
  ("jsonq", "jsonq", ".users[", JsonDoc, "jsonq: not a path: .users[\n", 2),
  ("jsonq", "jsonq", ".a", "{\"a\": [1, 2,]}", "jsonq: stdin is not JSON\n", 2),
  # a missing cell is counted, not averaged; a text column gets its top value
  ("csvstats", "csvstats", "", CsvDoc,
   "column     | type   | filled | missing | min       | max       | mean      | median    | distinct | top\n" &
   "---------- | ------ | ------ | ------- | --------- | --------- | --------- | --------- | -------- | ------\n" &
   "city       | text   | 5      | 0       |           |           |           |           | 5        | Oslo\n" &
   "population | number | 4      | 1       | 231800.00 | 709037.00 | 438756.75 | 407095.00 |          | \n" &
   "area       | number | 5      | 0       | 41.42     | 465.30    | 216.10    | 71.92     |          | \n" &
   "country    | text   | 5      | 0       |           |           |           |           | 3        | Norway\n", 0),
  # another separator; a negative number, and a missing cell
  ("csvstats", "csvstats", "--sep \";\"", "name;score\nann;-1.5\nbo;2\ncy;\ndi;0.25\n",
   "column | type   | filled | missing | min   | max  | mean | median | distinct | top\n" &
   "------ | ------ | ------ | ------- | ----- | ---- | ---- | ------ | -------- | ---\n" &
   "name   | text   | 4      | 0       |       |      |      |        | 4        | ann\n" &
   "score  | number | 3      | 1       | -1.50 | 2.00 | 0.25 | 0.25   |          | \n", 0),
  ("csvstats", "csvstats", "", "",
   "csvstats: stdin is not CSV with a header and a row\n", 2),
  # plain files only, in name order; never over an existing file
  ("tidy", "tidy", "--dry-run demo", "",
   "Makefile -> other/Makefile\nbuild.tar.gz -> archives/build.tar.gz\n" &
   "holiday.JPG -> images/holiday.JPG\nskip notes.md (documents/notes.md exists)\n" &
   "script.py -> code/script.py\nsong.mp3 -> audio/song.mp3\nwould move 5 of 6 files\n", 0),
  ("tidy", "tidy", "--dry-run --by-extension demo", "",
   "Makefile -> other/Makefile\nbuild.tar.gz -> gz/build.tar.gz\n" &
   "holiday.JPG -> jpg/holiday.JPG\nnotes.md -> md/notes.md\n" &
   "script.py -> py/script.py\nsong.mp3 -> mp3/song.mp3\nwould move 6 of 6 files\n", 0),
  ("tidy", "tidy", "", "", "tidy: name one folder\n", 2),
  # a whole session, one command per line; /dev/null reads empty and keeps nothing
  ("todo-cli", "todo", "--file /dev/null shell",
   "add buy milk\n" &
   "add ship it --urgent\n" &
   "add call mum\n" &
   "list\n" &
   "done 2\n" &
   "list\n" &
   "list --all\n" &
   "remove 1\n" &
   "list --all\n" &
   "done 9\n" &
   "done x\n" &
   "add\n",
   "added 1: buy milk\n" &
   "added 2: ship it\n" &
   "added 3: call mum\n" &
   "1. [ ] buy milk\n" &
   "2. [ ] ship it (urgent)\n" &
   "3. [ ] call mum\n" &
   "done 2: ship it\n" &
   "1. [ ] buy milk\n" &
   "3. [ ] call mum\n" &
   "1. [ ] buy milk\n" &
   "2. [x] ship it (urgent)\n" &
   "3. [ ] call mum\n" &
   "removed 1: buy milk\n" &
   "1. [x] ship it (urgent)\n" &
   "2. [ ] call mum\n" &
   "todo: no task 9\n" &
   "todo: not a number: x\n" &
   "todo: add what?\n", 2),
  ("todo-cli", "todo", "--file /dev/null", "", "nothing to do\n", 0),
  # a changed line reads as its old text, then its new one
  ("diff-patch", "diffpatch", "a.txt b.txt", "",
   "--- a.txt\n" &
   "+++ b.txt\n" &
   "@@ -1,5 +1,6 @@\n" &
   " alpha\n" &
   " bravo\n" &
   "-charlie\n" &
   "+charline\n" &
   " delta\n" &
   "+foxtrot\n" &
   " echo\n", 1),
  # three hunks: changes further apart than twice the context
  ("diff-patch", "diffpatch", "long-a.txt long-b.txt", "",
   "--- long-a.txt\n" &
   "+++ long-b.txt\n" &
   "@@ -1,5 +1,5 @@\n" &
   " line 1\n" &
   "-line 2\n" &
   "+line two\n" &
   " line 3\n" &
   " line 4\n" &
   " line 5\n" &
   "@@ -7,7 +7,6 @@\n" &
   " line 7\n" &
   " line 8\n" &
   " line 9\n" &
   "-line 10\n" &
   " line 11\n" &
   " line 12\n" &
   " line 13\n" &
   "@@ -17,4 +16,5 @@\n" &
   " line 17\n" &
   " line 18\n" &
   " line 19\n" &
   "+line 19.5\n" &
   " line 20\n", 1),
  ("diff-patch", "diffpatch", "long-a.txt long-b.txt --context 1", "",
   "--- long-a.txt\n" &
   "+++ long-b.txt\n" &
   "@@ -1,3 +1,3 @@\n" &
   " line 1\n" &
   "-line 2\n" &
   "+line two\n" &
   " line 3\n" &
   "@@ -9,3 +9,2 @@\n" &
   " line 9\n" &
   "-line 10\n" &
   " line 11\n" &
   "@@ -19,2 +18,3 @@\n" &
   " line 19\n" &
   "+line 19.5\n" &
   " line 20\n", 1),
  # the same file: nothing printed, exit 0, as diff does
  ("diff-patch", "diffpatch", "a.txt a.txt", "",
   "", 0),
  ("diff-patch", "diffpatch", "a.txt nope.txt", "",
   "diffpatch: cannot read nope.txt\n", 2),
  # a swapped pair is one edit (wrold -> world); an apostrophe inside a word is part of it
  ("spellchecker", "spellcheck", "", SpellText,
   "1:5 quik -> quick\n" &
   "1:26 ovar -> over\n" &
   "1:35 lazi -> lazy\n" &
   "2:7 worry -> word\n" &
   "2:27 can't -> can\n" &
   "2:33 know -> not\n" &
   "3:8 wrold -> world\n", 1),
  # no suggestion further than N edits
  ("spellchecker", "spellcheck", "--distance 0", SpellText,
   "1:5 quik\n" &
   "1:26 ovar\n" &
   "1:35 lazi\n" &
   "2:7 worry\n" &
   "2:27 can't\n" &
   "2:33 know\n" &
   "3:8 wrold\n", 1),
  # every word known: silent, exit 0
  ("spellchecker", "spellcheck", "", "the lazy dog\n",
   "", 0),
  ("spellchecker", "spellcheck", "--words nope.txt", "",
   "spellcheck: cannot read nope.txt\n", 2),
  # a file, with its type and length
  ("serve", "serve", "--stdio --dir site", "GET /hello.txt HTTP/1.1\r\nHost: x\r\n\r\n",
   "HTTP/1.1 200 OK\r\n" &
   "Content-Type: text/plain; charset=utf-8\r\n" &
   "Content-Length: 17\r\n" &
   "\r\n" &
   "hello from serve\n", 0),
  # a folder without index.html is listed: folders first, names encoded and escaped
  ("serve", "serve", "--stdio --dir site", "GET / HTTP/1.1\r\n\r\n",
   "HTTP/1.1 200 OK\r\n" &
   "Content-Type: text/html; charset=utf-8\r\n" &
   "Content-Length: 225\r\n" &
   "\r\n" &
   "<!doctype html>\n" &
   "<title>/</title>\n" &
   "<h1>/</h1>\n" &
   "<ul>\n" &
   "<li><a href=\"notes/\">notes/</a></li>\n" &
   "<li><a href=\"two%20words/\">two words/</a></li>\n" &
   "<li><a href=\"data.json\">data.json</a></li>\n" &
   "<li><a href=\"hello.txt\">hello.txt</a></li>\n" &
   "</ul>\n", 0),
  # a folder named without its slash is redirected to it
  ("serve", "serve", "--stdio --dir site", "GET /notes HTTP/1.1\r\n\r\n",
   "HTTP/1.1 301 Moved Permanently\r\n" &
   "Content-Type: text/plain; charset=utf-8\r\n" &
   "Location: /notes/\r\n" &
   "Content-Length: 22\r\n" &
   "\r\n" &
   "301 Moved Permanently\n", 0),
  ("serve", "serve", "--stdio --dir site", "GET /notes/ HTTP/1.1\r\n\r\n",
   "HTTP/1.1 200 OK\r\n" &
   "Content-Type: text/html; charset=utf-8\r\n" &
   "Content-Length: 60\r\n" &
   "\r\n" &
   "<!doctype html>\n" &
   "<title>notes</title>\n" &
   "<p>Served by Tuck.</p>\n", 0),
  # nothing outside the folder
  ("serve", "serve", "--stdio --dir site", "GET /../serve.tuck HTTP/1.1\r\n\r\n",
   "HTTP/1.1 403 Forbidden\r\n" &
   "Content-Type: text/plain; charset=utf-8\r\n" &
   "Content-Length: 14\r\n" &
   "\r\n" &
   "403 Forbidden\n", 0),
  ("serve", "serve", "--stdio --dir site", "GET /nope.txt HTTP/1.1\r\n\r\n",
   "HTTP/1.1 404 Not Found\r\n" &
   "Content-Type: text/plain; charset=utf-8\r\n" &
   "Content-Length: 14\r\n" &
   "\r\n" &
   "404 Not Found\n", 0),
  ("serve", "serve", "--stdio --dir site", "POST / HTTP/1.1\r\n\r\n",
   "HTTP/1.1 405 Method Not Allowed\r\n" &
   "Content-Type: text/plain; charset=utf-8\r\n" &
   "Allow: GET, HEAD\r\n" &
   "Content-Length: 23\r\n" &
   "\r\n" &
   "405 Method Not Allowed\n", 0),
  # HEAD: the head GET would send, length included
  ("serve", "serve", "--stdio --dir site", "HEAD /data.json HTTP/1.1\r\n\r\n",
   "HTTP/1.1 200 OK\r\n" &
   "Content-Type: application/json\r\n" &
   "Content-Length: 13\r\n" &
   "\r\n", 0),
  ("serve", "serve", "--stdio --dir site", "hello\n\n",
   "HTTP/1.1 400 Bad Request\r\n" &
   "Content-Type: text/plain; charset=utf-8\r\n" &
   "Content-Length: 16\r\n" &
   "\r\n" &
   "400 Bad Request\n", 0),
]

type Backend = tuple[label, flag, suffix: string]

proc backends(): seq[Backend] =
  result = @[("Nim", "", ""), ("Odin", "--odin", "_odin")]
  if findDmd().len > 0: result.add ("D", "--dlang", "_d")

proc buildDir(t: T, c: AppCase, b: Backend): string =
  t.curDir / (c.dir & "-" & b.label)

proc run*(t: var T) =
  ## Registers one build per program and backend, and one run per case.
  t.src "fn main() -> int:\n  return 0\n"
  let tuck = absolutePath(tuckExe)
  var builds: seq[tuple[key: string, idx: int]]
  var runs: seq[tuple[c: AppCase, b: Backend, idx: int]]
  for c in Cases:
    for b in backends():
      let dir = t.buildDir(c, b)
      let key = dir
      var bIdx = -1
      for (k, i) in builds:
        if k == key: bIdx = i
      if bIdx < 0:
        let src = t.root / "stdlib-project" / "apps" / c.dir
        let dmdPath = if b.label == "D": "PATH=" & parentDir(findDmd()) & ":$PATH " else: ""
        bIdx = t.needCmd(@["sh", "-c", "mkdir -p " & dir & " && cp -r " & src & "/. " &
            dir & " && cd " & dir & " && " & dmdPath & tuck & " b " & c.file &
            ".tuck " & b.flag & " --stdlib:stdlib-project --root:" & t.root &
            " > build.log 2>&1"], verb = vBuild)
        builds.add (key, bIdx)
      let cmd = "cd " & dir & " && printf %s " & quoteShell(c.input) & " | ./" &
                c.file & b.suffix & " " & c.args
      runs.add (c, b, t.needCmdAfter(@["sh", "-c", cmd], bIdx,
                                     proc (d: string) = discard, dir, verb = vRun))
  if t.phase == pCollect: return
  for (c, b, idx) in runs:
    let title = c.dir & " " & c.args & " on " & b.label
    if t.skippedCmd(idx): t.skip title; continue
    let (rc, outp) = t.resultOf(idx)
    if rc == c.code and outp == c.want: t.ok title
    else:
      t.no title, "exit " & $rc & " (want " & $c.code & ")\n--- got\n" & outp &
                  "--- want\n" & c.want
  t.finish()
