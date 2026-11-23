# frozen_string_literal: true

module Flexr
  module Runtime
    class BackupMemo
      BLOCK_BITS = 10
      BLOCK_MASK = (1 << BLOCK_BITS) - 1

      def initialize
        @blocks = {}
        @first_block = nil
        @visits = []
      end

      def discard_before(position)
        block = position >> BLOCK_BITS
        return if block == @first_block

        if @first_block && block >= @first_block
          while @first_block < block
            @blocks.delete(@first_block)
            @first_block += 1
          end
        else
          @blocks.clear
        end
        @first_block = block
      end

      def failed_end(state, position)
        @blocks&.[](position >> BLOCK_BITS)&.[]((state << BLOCK_BITS) | (position & BLOCK_MASK))
      end

      def visit(state, position)
        @visits.push(position, (state << BLOCK_BITS) | (position & BLOCK_MASK))
      end

      def clear_attempt
        @visits.clear
      end

      def finish(position)
        if @blocks
          index = 0
          while index < @visits.length
            block = (@blocks[@visits[index] >> BLOCK_BITS] ||= {})
            block[@visits[index + 1]] = position
            index += 2
          end
        end
        clear_attempt
      end

      def disable!
        clear_attempt
        @blocks = nil
      end
    end

    module BackupScanning
      def on_error=(handler)
        @on_error = handler
        @interpreter = nil
        @generated_scanner = use_generated_scanner?
        handler
      end

      def __flexr_backup_suffix(dfa, memo_states, state, cursor, start)
        # Leave raw acceptances to the caller so token selection can apply its own constraints.
        return if scan_steps_guarded?

        memo = @buffer.backup_memo(dfa)
        return unless memo

        text_start = @more_start || start
        limit = text_start + @max_token_size if @token_limit_required
        memo.discard_before(start)
        ending = memo.failed_end(state, cursor)
        return false if ending && (!limit || ending <= limit)

        source = @buffer.backup_scan_source
        accepts = dfa.accepts
        memo.clear_attempt
        loop do
          memo.visit(state, cursor) if memo_states[state]
          byte = source ? source.getbyte(cursor) : @buffer.getbyte(cursor)
          break unless byte

          state = dfa.transition(state, byte)
          break unless state

          cursor += 1
          acceptance = accepts[state].first
          defer_token_size_check!(cursor - text_start, rule: acceptance&.rule_index) if limit && cursor > limit
          if acceptance
            memo.clear_attempt
            return [state, cursor]
          end

          next unless memo_states[state]

          ending = memo.failed_end(state, cursor)
          if ending && (!limit || ending <= limit)
            cursor = ending
            break
          end
        end
        memo.finish(cursor)
        false
      end

      private

      def use_generated_scanner?
        return false unless super

        !__flexr_recovers_unmatched? ||
          self.class.__flexr_compiled.machines.values.none?(&:backup_recovery_states)
      end
    end
    prepend BackupScanning

    class Buffer
      module StreamExposure
        def source
          return exposed_source if @window_start.zero?

          super
        end

        def stable_source
          super && exposed_source
        end

        private

        def exposed_source
          unless @source_exposed || @source.frozen?
            # A caller may change any loaded byte once it can reach the backing String.
            @source_exposed = true
            @backup_memos&.each_value(&:disable!)
            @backup_memos = nil
          end
          @source
        end
      end

      module BackupStorage
        def initialize(...)
          super
          extend StreamExposure if @io
        end

        def backup_scan_source
          @source if @retain_input && @source.frozen? && @window_start.zero? && base_offset.zero?
        end

        def backup_memo(dfa)
          return unless @source.frozen? || (@io && !@source_exposed)

          (@backup_memos ||= {}.compare_by_identity)[dfa] ||= BackupMemo.new
        end

        private

        def prune_backup_memos(ending)
          @backup_memos.each_value { |memo| memo.discard_before(ending) } if
            (ending >> BackupMemo::BLOCK_BITS) != (base_offset >> BackupMemo::BLOCK_BITS)
        end
      end
      prepend BackupStorage
    end
  end
end
