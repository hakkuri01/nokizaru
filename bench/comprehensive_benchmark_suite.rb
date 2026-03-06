#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/comprehensive_suite'

exit(Bench::ComprehensiveSuite::CLI.run(ARGV))
