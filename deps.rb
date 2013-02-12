require 'bundler'
require 'octokit'
require 'gemnasium/parser'
require 'base64'
require 'xlsx_writer'

module Gemnasium
  module Parser
    class Gemfile
      # Don't exclude any gems, dude. Gem discrimination is wrong.
      def exclude?(match, opts)
        false
      end
    end
  end
end


def client
  @client ||= Octokit::Client.new(:login => ENV['GITHUB_USERNAME'], :oauth_token => ENV['GITHUB_AUTH_TOKEN'])
end

def gems
  @gems ||= {}
end

def version_of(dependency)
  dependency.send(dependency.respond_to?(:version) ? :version : :requirement).to_s
end

def add_dependency_for(repo, dependency)
  (gems[ [dependency.name, version_of(dependency), dependency.source.to_s] ] ||= []) << repo
end

def decoded_content(content)
  # content.encoding.eql?('base64') ? Base64.decode64(content) : content
  Base64.decode64(content)
end

def note_dependencies_for(repo, branch_name)
  lock_blob = client.contents(repo.full_name, :path => 'Gemfile.lock', :ref => branch_name) rescue nil
  gemfile_blob = client.contents(repo.full_name, :path => 'Gemfile', :ref => branch_name) rescue nil
  if lock_blob# && gemfile_blob
    puts "Parsing #{repo.full_name}@#{branch_name}'s Gemfile.lock"
    # Gem groups can be collected from the Gemfile
    # gemfile = Gemnasium::Parser.gemfile(decoded_content(gemfile_blob))
    # gem_groups = gemfile.dependencies.inject({}){|h, g| h.merge!(g.name => g.groups)}
    # gemfile.dependencies.each{|dep| add_dependency_for("#{repo.name}@#{branch_name}", dep)}
    lockfile = Bundler::LockfileParser.new(decoded_content(lock_blob.content))
    lockfile.specs.each{|spec| add_dependency_for("#{repo.name}@#{branch_name}", spec)}
  else
    puts "Couldn't find a Gemfile.lock in #{repo.full_name}@#{branch_name}"
  end
end

client.organization_repositories('mdsol').each do |repo|
  ['master', 'develop', 'release'].each do |branch_name|
    note_dependencies_for(repo, branch_name)
  end
end

puts "Gem count: #{gems.keys.count}"

doc = XlsxWriter::Document.new
sheet1 = doc.add_sheet 'Used in Released Products'
sheet1.add_row ['Free & Open Source Software (FOSS) Usage [in Medidata Products]']
sheet1.add_row []
sheet1.add_row ['FOSS Software Name', 'Version', 'Requestor', 'License', 'For Use in Medidata Products', 'URL of Software Application', 'Internal Repository']
sheet1.add_autofilter 'A3:G3'
gems.sort_by{|((gem_name, _), _)| gem_name}.each do |(gem_name, gem_version, gem_source), repos_using_gem|
  sheet1.add_row [
    gem_name,
    gem_version,
    '', # Requestor
    '', # License
    repos_using_gem.join(', '),
    gem_source,
    (gem_source && "#{gem_source}".include?('github.com:mdsol/')) ? 'yes' : 'no'
  ]
end
require 'fileutils'
FileUtils.mv doc.path, "./foss.xlsx"
doc.cleanup
