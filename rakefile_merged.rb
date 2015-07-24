
require 'csv'
require 'erb'
require 'fileutils'
require 'json'
require 'open-uri'
require 'pry'
require 'rake/clean'

def json_load(file)
  return unless File.exist? file
  JSON.parse(File.read(file), symbolize_names: true)
end

@instructions = json_load('instructions.json') 
raise "No sources" if @instructions[:sources].count.zero?

@recreatable = @instructions[:sources].find_all { |i| i.key? :create }
CLOBBER.include FileList.new(@recreatable.map { |i| i[:file] })

# For now, write the merged file to manual/members.csv so we can then
# fall-back on the old-style rake task that looks there
# TODO: consolidate these
CLOBBER.include 'manual/members.csv'

def morph_select(src, qs)
  morph_api_key = ENV['MORPH_API_KEY'] or fail 'Need a Morph API key'
  key = ERB::Util.url_encode(morph_api_key)
  query = ERB::Util.url_encode(qs.gsub(/\s+/, ' ').strip)
  url = "https://api.morph.io/#{src}/data.csv?key=#{key}&query=#{query}"
  warn "Fetching #{url}"
  open(url).read
end

def fetch_missing
  @recreatable.each do |i|
    unless File.exist? i[:file]
      c = i[:create]
      raise "Don't know how to fetch #{i[:file]}" unless c[:type] == 'morph'
      data = morph_select(c[:scraper], c[:query])
      File.write(i[:file], data)
    end
  end 
end

# http://codereview.stackexchange.com/questions/84290/combining-csvs-using-ruby-to-match-headers
def combine_sources

  # build headers for everything
  all_headers = @instructions[:sources].map { |src| src[:file] }.reduce([]) do |all_headers, file|
    header_line = File.open(file, &:gets)     
    all_headers | CSV.parse_line(header_line) 
  end

  # First concat everything that's a "membership" (or default)
  all_rows = []
  @instructions[:sources].find_all { |src|
    src[:type].to_s.empty? || src[:type].to_s.downcase == 'membership'
  }.map { |src| src[:file] }.each do |file|
    CSV.table(file).each do |row|
      all_rows << row
    end
  end

  # Then merge in Person files
  @instructions[:sources].find_all { |src| 
    src[:type].to_s.downcase == 'person' 
  }.map { |src| src[:file] }.each do |file|
    CSV.table(file).each do |p|
      all_rows.find_all { |r| r[:id] == p[:id] }.each do |r|
        p.headers.each { |h| r[h] ||= p[h] }
      end
    end
  end

  # Then write it all out
  CSV.open("manual/members.csv", "w") do |out|
    out << all_headers
    all_rows.each { |r| out << all_headers.map { |header| r[header.to_sym] } }
  end
end

task :fetch_missing do
  fetch_missing
end

task 'manual/members.csv' => :fetch_missing do
  combine_sources
end

task :default => [ 'manual/members.csv' ]
