# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe "flexr skeleton" do
  def run_skeleton(source, *flags, directory: nil)
    return Dir.mktmpdir("flexr-skeleton-") { |dir| run_skeleton(source, *flags, directory: dir) } unless directory

    path = File.join(directory, "lexer.flexr.rb")
    File.binwrite(path, source)
    stdout = StringIO.new
    stderr = StringIO.new
    status = Flexr::CLI.run(["skeleton", path, *flags], out: stdout, err: stderr)
    [status, stdout.string, stderr.string]
  end

  it "reports shortest reaching inputs for each state and observes end anchors" do
    source = <<~RUBY
      class SkeletonLexer < Flexr::Lexer
        rule(/ab|c/, emit: :INITIAL)
        state :quoted do
          rule(/^q$/, emit: :ANCHORED)
          rule("qw", emit: :LONG)
        end
      end
    RUBY

    status, stdout, stderr = run_skeleton(source, "--format", "json")
    expect(status).to eq(0), stderr
    report = JSON.parse(stdout)
    expect(report.fetch("coverage")).to include("covered" => 5, "total" => 5, "uncovered" => [])
    grouped = report.fetch("cases").group_by { |item| item.fetch("state") }
    expect(grouped.fetch("initial").map { |item| item.fetch("input") }).to eq(["", "a", "c", "ab"])
    quoted = grouped.fetch("quoted").to_h { |item| [item.fetch("input"), item] }
    expect(quoted.keys).to eq(["", "q", "qw"])
    expect(quoted.fetch("q").fetch("rule_bodies")).to eq([{ "rule" => 1, "bytes" => 1 }])
    expect(quoted.fetch("qw").fetch("rule_bodies")).to eq([{ "rule" => 2, "bytes" => 2 }])
    covered = report.fetch("cases").flat_map do |item|
      item.fetch("transitions").map { |edge| [item.fetch("state"), edge] }
    end.uniq
    expect(covered.size).to eq(report.dig("coverage", "covered"))
    expect(report).not_to have_key("verification")
    expect(run_skeleton(source, "--format", "json")[1]).to eq(stdout)

    status, verified, stderr = run_skeleton(source, "--verify", "--format", "json", "--backend", "direct")
    expect(status).to eq(0), stderr
    expect(JSON.parse(verified).fetch("verification")).to include("matched" => 7, "compared" => 7)
  end

  it "completes UTF-8 witnesses and reports edges with no valid input" do
    source = <<~'RUBY'
      class SkeletonLexer < Flexr::Lexer
        rule(/é/, emit: :LETTER)
        rule(/\xFF/n, emit: :BYTE)
      end
    RUBY

    status, stdout, stderr = run_skeleton(source, "--format", "json")
    expect(status).to eq(0), stderr
    report = JSON.parse(stdout)
    expect(report.fetch("cases").map { |item| item.fetch("input") }).to eq(["", "é"])
    coverage = report.fetch("coverage")
    expect(coverage).to include("covered" => 2, "total" => 3)
    expect(coverage.fetch("uncovered")).to match([a_hash_including("state" => "initial", "reason" => "no_valid_input")])
    expect(report.fetch("cases").last.fetch("transitions").length).to eq(2)
  end

  it "does not count illegal UTF-8 continuations as covered transitions" do
    source = <<~'RUBY'
      class SkeletonLexer < Flexr::Lexer
        rule(/\xE0\x9F\x80|\xE0\xA0\x80/n, emit: :THREE_BYTES)
      end
    RUBY

    status, stdout, stderr = run_skeleton(source, "--format", "json")
    expect(status).to eq(0), stderr
    report = JSON.parse(stdout)
    expect(report.fetch("cases").map { |item| item.fetch("input").bytes }).to eq([[], [0xe0, 0xa0, 0x80]])
    coverage = report.fetch("coverage")
    expect(coverage).to include("covered" => 3, "total" => 4)
    expect(coverage.fetch("uncovered")).to match([a_hash_including("reason" => "no_valid_input")])
  end

  it "keeps static generation free of spec execution and verifies all three modes explicitly" do
    Dir.mktmpdir("flexr-skeleton-") do |directory|
      marker = File.join(directory, "executed")
      File.binwrite(File.join(directory, "helper.rb"), 'VERIFIED_VALUE = :FROM_HELPER')
      source = <<~RUBY
        require_relative "helper"
        class SkeletonLexer < Flexr::Lexer
          rule("ab") do
            File.binwrite(#{marker.inspect}, __FILE__)
            puts "action output"
            emit(VERIFIED_VALUE, text)
          end
        end
      RUBY

      status, stdout, stderr = run_skeleton(source, directory: directory)
      expect(status).to eq(0), stderr
      expect(stdout).to include("DFA transitions", '"ab"')
      expect(File).not_to exist(marker)
      status, stdout, stderr = run_skeleton(source, "--format", "json", "--verify", directory: directory)
      expect(status).to eq(0), stderr
      verification = JSON.parse(stdout).fetch("verification")
      expect(verification).to include(
        "modes" => %w[runtime generated standalone], "compared" => 3, "matched" => 3, "mismatches" => []
      )
      expect(File.binread(marker)).to eq(File.join(directory, "lexer.flexr.rb"))
    end
  end

  it "encodes binary input and returns a failed status when execution modes differ" do
    source = <<~'RUBY'
      class SkeletonLexer < Flexr::Lexer
        encoding Encoding::BINARY
        rule(/\xFF/n) { emit :BYTE, self.class.__flexr_generated? ? 2 : 1 }
      end
    RUBY

    status, stdout, stderr = run_skeleton(source, "--verify", "--format", "json")
    expect(status).to eq(1), stderr
    report = JSON.parse(stdout)
    expect(report.fetch("cases").last.fetch("input")).to eq({ "bytes" => [255] })
    expect(report.fetch("coverage")).to include("covered" => 1, "total" => 1)
    verification = report.fetch("verification")
    expect(verification).to include("matched" => 1, "compared" => 2)
    expect(verification.fetch("mismatches")).to match([
      a_hash_including("input" => { "bytes" => [255] }, "outcomes" => a_hash_including("runtime", "generated", "standalone"))
    ])
  end

  it "rejects the eval option without running the spec" do
    status, _stdout, stderr = run_skeleton('raise "executed"', "--eval")
    expect(status).to eq(2)
    expect(stderr).to include("skeleton requires static")
  end
end
