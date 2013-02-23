require 'base64'
require 'bundler'
require 'gemnasium/parser'
require 'gems'
require 'octokit'
require 'open-uri'
require 'ostruct'
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

module Bundler
  class Dependency
    attr_accessor :line # written to by Gemnasium::Parser and read by me when doing a git blame!
    attr_accessor :committer # written to by me to store who last touched the Gemfile at this line.
  end
end

class RepoData < Struct.new(:owner, :name, :branch)
  attr_accessor :dependencies

  @@info_cache = {}

  def dependencies
    @dependencies ||= []
  end

  def full_name
    "#{owner}/#{name}"
  end

  def specs
    @specs ||= {}
  end

  def github_url(spec)
    if spec.source.to_s =~ /^git@github.com:(.+).git \(at (.+)\)$/ # => https://github.com/$1/tree/$2
      "http://github.com/#{$1}/tree/#{$2}"
    else
      (@@info_cache[spec.name] ||= Gems.info(spec.name))['source_code_uri']
    end
  end

  def git_reference(spec)
    if spec.source.to_s =~ /^git@github.com:(.+).git \(at (.+)\)$/ # => https://github.com/$1/tree/$2
      $2
    end
  end

  def make_a_gem(spec)
    OpenStruct.new(
      :name => spec.name,
      :version => spec.version.to_s,
      :github_url => github_url(spec),
      :git_reference => git_reference(spec),
      :source => spec.source,
      :spec => spec
    )
  end

  def refined_gems
    puts "Refining gems for #{self}"
    gems = []
    # all_gem_dependencies = Marshal.load(open("http://rubygems.org/api/v1/dependencies?gems=#{dependencies.collect(&:name).join(',')}"))

    gem_groups = dependencies.each_with_object({}) do |dependency, hash|
      spec = specs[dependency.name]
      if spec && gemmy = make_a_gem(spec)
        # gem_dependencies_hash = all_gem_dependencies.detect{|h| h[:name] == gemmy.name && h[:version] == gemmy.version}
        # if gem_dependencies_hash.nil?
        #   if gemmy.github_url =~ /github.com\/([^\/]+\/[^\/]+)/ # client.contents(github_url(spec)[])
        #     # We have a github url so we know the repo full name (e.g. github.com/rails/rails => rails/rails)
        #     begin
        #       gemspec = Gemnasium::Parser.gemspec(decoded_content(
        #         client.contents($1, :path => "#{gemmy.name}.gemspec", :ref => gemmy.git_reference).content
        #       ))
        #       gemmy.dependent_gems = gemspec.dependencies.collect{|dep| specs[dep.name]}
        #     rescue
        #       debugger
        #       gemmy.dependent_gems = []
        #     end
        #   else
        #     # ¯\_(ツ)_/¯.
        #   end
        # else
        #   gemmy.dependent_gems = gem_dependencies_hash[:dependencies].collect{|(name, requirement)| make_a_gem(specs[name])}
        # end
        gemmy.dependent_gems = spec.dependencies.collect do |dep|
          if specs[dep.name]
            make_a_gem(specs[dep.name])
          else
            puts "Hm, looks like we don't have a spec for #{dep.name} for #{gemmy.name}"
          end
        end.compact
        dependency.groups.each{|group| (hash[group] ||= []).concat([gemmy, *gemmy.dependent_gems])}
      else
        puts "Oh noes, no spec for #{dependency.name}"
      end
    end
  end

  def to_s
    "#{name}@#{branch}"
  end
end


def client
  @client ||= Octokit::Client.new(:login => ENV['GITHUB_USERNAME'], :oauth_token => ENV['GITHUB_AUTH_TOKEN'])
end

def repos_using_gem
  @gems ||= {}
end

def add_dependency_for(repo, dependency)
  repo.specs[dependency.name] = dependency
  (repos_using_gem[dependency.name] ||= []) << repo
end

def decoded_content(content)
  # content.encoding.eql?('base64') ? Base64.decode64(content) : content
  Base64.decode64(content)
end

def all_repo_data
  @repo_data ||= []
end

def note_dependencies_for(repo, branch_name)
  lock_blob = client.contents(repo.full_name, :path => 'Gemfile.lock', :ref => branch_name) rescue nil
  gemfile_blob = client.contents(repo.full_name, :path => 'Gemfile', :ref => branch_name) rescue nil
  repo_data = RepoData.new(repo.owner.login, repo.name, branch_name)

  if gemfile_blob
    # Gem groups can be collected from the Gemfile
    puts "Parsing #{repo.full_name}@#{branch_name}'s Gemfile"
    gemfile = Gemnasium::Parser.gemfile(decoded_content(gemfile_blob.content))
    repo_data.dependencies = gemfile.dependencies
  else
    puts "Couldn't find a Gemfile in #{repo.full_name}@#{branch_name}"
  end

  if lock_blob
    puts "Parsing #{repo.full_name}@#{branch_name}'s Gemfile.lock"
    lockfile = Bundler::LockfileParser.new(decoded_content(lock_blob.content))
    lockfile.specs.each{|spec| add_dependency_for(repo_data, spec)}
  else
    puts "Couldn't find a Gemfile.lock in #{repo.full_name}@#{branch_name}"
  end
  all_repo_data << repo_data if gemfile_blob && lock_blob
end

def gems_by_group
  @gems_by_group ||= Hash.new{|h, k| h[k] = Set.new}
end

if ENV['READ_DUMP']
  @repo_data = Marshal.load(File.read('all_repo_data.dump'))
else
  client.organization_repositories('mdsol').each do |repo|
    ['master', 'develop', 'release'].each do |branch_name|
      note_dependencies_for(repo, branch_name)
    end
  end
  File.open('all_repo_data.dump', 'w'){|f| f.print Marshal.dump(all_repo_data)}
end

all_repo_data.each do |repo_data|
  repo_data.refined_gems.each_pair do |group, gems|
    gems_by_group[group].merge(gems)
  end
end

prod_gems = gems_by_group[:default]
dev_gems = gems_by_group.each_with_object(Set.new) do |(group, gems), set|
  set.merge(group == :default ? [] : gems)
end

puts "Gem count: prod - #{prod_gems.count}, dev - #{dev_gems.count}"

def fill_sheet(sheet, gems)
  sheet.add_row ['Free & Open Source Software (FOSS) Usage [in Medidata Products]']
  sheet.add_row []
  sheet.add_row [
    'FOSS Software Name',
    'Version',
    'Requestor',
    'License',
    'For Use in Medidata Products',
    'URL of Software Application',
    'Internal Repository'
  ]
  sheet.add_autofilter 'A3:G3'
  gems.sort_by(&:name).each do |gemmy|
    sheet.add_row [
      gemmy.name,
      gemmy.version,
      '', # Requestor
      '', # License
      repos_using_gem[gemmy.name].join(', '),
      "#{gemmy.github_url.blank? ? gemmy.source : gemmy.github_url}",
      (gemmy.source && "#{gemmy.source}".include?('github.com:mdsol/')) ? 'yes' : 'no'
    ]
  end
end

doc = XlsxWriter::Document.new
fill_sheet(doc.add_sheet('Used in Released Products'), prod_gems)
fill_sheet(doc.add_sheet('Used Internally at Medidata'), dev_gems)

require 'fileutils'
FileUtils.mv doc.path, "./foss.xlsx"
doc.cleanup
