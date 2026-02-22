# frozen_string_literal: true

require 'set'
require_relative '../log'
require_relative '../target_intel'
require_relative 'crawler/core'
require_relative 'crawler/http'
require_relative 'crawler/http_support'
require_relative 'crawler/links'
require_relative 'crawler/link_support'
require_relative 'crawler/sitemaps'
require_relative 'crawler/javascript'
require_relative 'crawler/stats'
require_relative 'crawler/threads'

module Nokizaru
  module Modules
    # Crawler module orchestration
    module Crawler
      module_function

      extend Crawler::Core
      extend Crawler::Http
      extend Crawler::HttpSupport
      extend Crawler::Links
      extend Crawler::LinkSupport
      extend Crawler::Sitemaps
      extend Crawler::JavaScript
      extend Crawler::Stats
      extend Crawler::Threads

      TIMEOUT = 10
      USER_AGENT = 'Nokizaru'
      PREVIEW_LIMIT = 8
      MAX_FETCH_WORKERS = 8
      MAX_SITEMAPS = 200
      MAX_MAIN_REDIRECTS = 2
      REDIRECT_CODES = Set[301, 302, 303, 307, 308].freeze
      STEP_LABELS = [
        'Looking for robots.txt',
        'Extracting robots Links',
        'Looking for sitemap.xml',
        'Extracting CSS Links',
        'Extracting JavaScript Links',
        'Extracting Internal Links',
        'Extracting External Links',
        'Extracting Image Links',
        'Crawling Sitemaps',
        'Crawling Javascripts'
      ].freeze
      STEP_LABEL_WIDTH = STEP_LABELS.map(&:length).max

      def call(target, _protocol, _netloc, ctx)
        result = initialize_result
        UI.module_header('Starting Crawler...')
        page = crawl_main_page(target, ctx, result)
        return if page.nil?

        crawl_page_resources!(result, page)
        finalize_crawl!(ctx, result)
      end

      def step_row(type, label, value)
        UI.row(type, label, value, label_width: STEP_LABEL_WIDTH)
      end
    end
  end
end
