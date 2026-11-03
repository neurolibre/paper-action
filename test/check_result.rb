#!/usr/bin/env ruby
# Check the warning comment check_result.rb posts to the review issue.
#
# The script is run as the action runs it, against generated files and pandoc
# JSON logs written to a scratch directory. `gh` is replaced on PATH by a stub,
# so nothing is posted; the comment is read back from oj_warnings.txt, which
# the script writes before calling `gh`.
#
# Usage: ruby test/check_result.rb

require "json"
require "tmpdir"

script = File.expand_path("../check_result.rb", __dir__)
failures = 0

def check(name, condition, detail)
  if condition
    puts "ok   #{name}"
    true
  else
    puts "FAIL #{name}\n#{detail}"
    false
  end
end

Dir.mktmpdir do |dir|
  paper = File.join(dir, "paper.md")
  %w[paper.md paper.pdf paper.crossref paper.jats].each do |f|
    File.write(File.join(dir, f), "")
  end

  # The warnings the issue 52 JATS run produced, plus one in the Crossref log.
  # pandoc's CouldNotFetchResource entry keeps the image in `path`.
  File.write(File.join(dir, "paper.crossref.log"), JSON.generate([
    {"verbosity" => "INFO", "type" => "LoadedResource", "path" => "x", "message" => "ignored"},
    {"verbosity" => "WARNING", "type" => "DuplicateIdentifier", "source" => "sec-intro",
     "message" => "duplicate identifier"},
  ]))
  File.write(File.join(dir, "paper.jats.log"), JSON.generate([
    {"verbosity" => "WARNING", "type" => "CouldNotFetchResource",
     "path" => "#notebook_tbl_demographics.png", "message" => "replacing image with description"},
    {"verbosity" => "WARNING", "type" => "CouldNotFetchResource",
     "path" => "#notebook_table_ancovaResults_significant.png", "message" => "replacing image with description"},
  ]))

  bin = File.join(dir, "bin")
  Dir.mkdir(bin)
  File.write(File.join(bin, "gh"), "#!/bin/sh\nexit 0\n")
  File.chmod(0o755, File.join(bin, "gh"))

  env = {
    "PATH" => "#{bin}:#{ENV["PATH"]}",
    "GITHUB_OUTPUT" => File.join(dir, "github_output"),
    "ISSUE_ID" => "52",
  }
  system(env, "ruby", script, paper, "neurolibre,crossref,jats",
         chdir: dir, out: File::NULL, exception: true)

  comment_path = File.join(dir, "oj_warnings.txt")
  comment = File.exist?(comment_path) ? File.read(comment_path) : ""

  failures += 1 unless check("names the image each warning is about",
    comment.include?("replacing image with description: #notebook_tbl_demographics.png") &&
      comment.include?("replacing image with description: #notebook_table_ancovaResults_significant.png"),
    comment)
  failures += 1 unless check("names the source of warnings that have no path",
    comment.include?("duplicate identifier: sec-intro"), comment)
  failures += 1 unless check("reports the JATS log even when the Crossref log has warnings",
    comment.include?("#notebook_tbl_demographics.png"), comment)
  failures += 1 unless check("leaves out entries below WARNING",
    !comment.include?("ignored"), comment)
end

if failures > 0
  puts "\n#{failures} check(s) failed"
  exit 1
end
puts "\nall checks passed"
