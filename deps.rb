require 'bundler'
require 'octokit'
require 'gemnasium/parser'
require 'base64'

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
# lockfile = Bundler::LockfileParser.new(Bundler.read_file("Gemfile.lock"))

@gems = {}

def add_dependency_for(repo, dependency)
  (@gems[[dependency.name, dependency.version.to_s, dependency.source.to_s]] ||= []) << repo
end

def note_dependencies_for(repo, branch_name)
  blob = client.contents(repo.full_name, :path => 'Gemfile.lock', :ref => branch_name) rescue nil
  if blob.nil?
    puts "Couldn't find a Gemfile.lock in #{repo.full_name}@#{branch_name}"
  else
    content = blob.encoding.eql?('base64') ? Base64.decode64(blob.content) : blob.content
    puts "Parsing #{repo.full_name}@#{branch_name}'s Gemfile.lock"
    #Gemnasium::Parser.gemfile(content).dependencies.each{|dep| add_dependency_for("#{repo.name}@#{branch_name}", dep)}
    Bundler::LockfileParser.new(content).specs.each{|spec| add_dependency_for("#{repo.name}@#{branch_name}", spec)}
  end
end

client.organization_repositories('mdsol').each do |repo|
  ['master', 'develop', 'release'].each do |branch_name|
    note_dependencies_for(repo, branch_name)
  end
end

require 'pp'
pp @gems

# @gems.each_pair do |(gem_name, gem_version, gem_source), repos_using_gem|
#   puts %[#{gem_name}, #{gem_version}, #{gem_source}, "#{repos_using_gem.join(', ')}"]
# end
