# frozen_string_literal: true

module Flexr
  module Runtime
    class ChannelToken < Token
      attr_reader :channel, :leading_trivia

      def initialize(type:, value:, location:, channel: :default, leading_trivia: EMPTY_TRIVIA)
        @channel = channel
        @leading_trivia = leading_trivia.freeze
        super(type: type, value: value, location: location)
      end

      def with(**changes)
        return self if changes.empty?

        self.class.new(**to_h, channel: channel, leading_trivia: leading_trivia, **changes)
      end
    end

    module Channels
      def tokens(channels: :default)
        previous = @__flexr_all_channels
        @__flexr_all_channels = channels == :all
        super
      ensure
        @__flexr_all_channels = previous
      end

      def next_token(...)
        loop do
          @__flexr_token_channel = nil
          @__flexr_recovery_token = nil
          token = super
          unless token
            @__flexr_leading_trivia = nil
            return
          end

          if @__flexr_token_channel
            if @token_kind == :struct
              token = ChannelToken.new(**token.to_h, channel: @__flexr_token_channel)
              (@__flexr_leading_trivia ||= []) << token
            end
            return token if @__flexr_all_channels
          else
            return token unless @__flexr_leading_trivia

            trivia = @__flexr_leading_trivia
            @__flexr_leading_trivia = nil
            return ChannelToken.new(**token.to_h, leading_trivia: trivia)
          end
        end
      end

      def error!(message)
        result = super
        @__flexr_recovery_token = @pending
        result
      end

      private

      def execute(rule)
        super
        @__flexr_token_channel = rule.channel unless @pending.equal?(@__flexr_recovery_token)
      end
    end
  end
end
