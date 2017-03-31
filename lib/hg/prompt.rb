module Hg
  class Prompt
    extend Forwardable

    # @api private
    attr_reader :output

    def_delegators :@output, :print

    def self.messages
      {
        range?: 'Value %{value} must be within the range %{in}',
        valid?: 'Your answer is invalid (must match %{valid})',
        required?: 'Value must be provided'
      }
    end

    # @api public
    def initialize(options = {})
      @output = options.fetch(:output)
    end

    # Invoke a question type of prompt.
    #
    # @example
    #   prompt = TTY::Prompt.new
    #   prompt.invoke_question(Question, "Your name? ")
    #
    # @return [String]
    #
    # @api public
    def invoke_question(object, message, *args, &block)
      options = Utils.extract_options!(args)
      options[:messages] = self.class.messages
      question = object.new(self, options)
      question.(message, &block)
    end

    # Ask a question.
    #
    # @example
    #   propmt = TTY::Prompt.new
    #   prompt.ask("What is your name?")
    #
    # @param [String] message
    #   The question to be asked.
    #
    # @yieldparam [TTY::Prompt::Question] question
    #   Further configure the question.
    #
    # @yield [question]
    #
    # @return [TTY::Prompt::Question]
    #
    # @api public
    def ask(message, *args, &block)
      invoke_question(Hg::Prompt::Question, message, *args, &block)
    end
  end
end