# frozen_string_literal: true

# Generates the deterministic JSON corpus used by the benchmark plan.
#
#   ruby benchmark/corpora/generate_json.rb > benchmark/corpora/json_10mb.json

TARGET_BYTES = Integer(ENV.fetch("FLEXR_JSON_BYTES", "10_000_000"), 10)
PADDING_BYTES = Integer(ENV.fetch("FLEXR_JSON_PADDING_BYTES", "0"), 10)
abort "FLEXR_JSON_PADDING_BYTES must not be negative" if PADDING_BYTES.negative?

RECORD = %({"answer":42#{' ' * PADDING_BYTES},"name":"flexr"}).freeze

abort "FLEXR_JSON_BYTES must be at least #{RECORD.bytesize + 3}" if RECORD.bytesize + 3 > TARGET_BYTES

json = +"["
first = true
while json.bytesize + RECORD.bytesize + 1 < TARGET_BYTES
  json << "," unless first
  json << RECORD
  first = false
end
json << (" " * (TARGET_BYTES - json.bytesize - 1))
json << "]"
abort "generated corpus has #{json.bytesize} bytes, expected #{TARGET_BYTES}" unless json.bytesize == TARGET_BYTES

print json
