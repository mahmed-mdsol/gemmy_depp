require 'base64'
require 'bundler'
require 'gemnasium/parser'
require 'gems'
require 'octokit'
require 'open-uri'
require 'ostruct'
require 'xlsx_writer'

require 'ruby-debug'

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

class Gemmy < OpenStruct
  # Adapted from https://github.com/dblock/gem-licenses/blob/master/lib/gem_specification.rb
  LICENSE_REGEXES = [
    /See the (?<l>.+) Licen[sc]e/i,
    /(?<l>MIT|L?GPL|BSD|Apache).LICEN[SC]E/i,
    /(?<l>GNU General Public).Licen[cs]e/i,
    /(?<l>GPL version \d+)/i,
    /same license as [^\w]*(?<l>[\s\w]+)/i,
    /(?:released|available) under (?:the|a|an) [^\w]*(?<l>[\s\w]+)(?:-style)?[^\w]* license/i,
    /^[^\w]*(?<l>[\s\w]+)[^\w]* License, see/i,
    /^(?<l>[\w]+)[^\w]* license$/i,
    /\(the [^\w]*(?<l>[\s\w]+)[^\w]* license\)/i,
    /^license: [^\w]*(?<l>[\s\w]+)/i,
    /^released under the [^\w]*(?<l>[\s\w]+)[^\w]* license/i,
  ]

  def licenses_per_rubygems
    versions = Gems.versions(name)
    if versions.respond_to?(:detect)
      version_data = versions.detect{|v| v['number'] == version} || {}
      [*version_data['licenses']]
    else
      []
    end
  end

  def extract_licenses
    if @licenses.nil? && github_url =~ /github.com\/([^\/]+\/[^\/]+)/i
      full_repo_name = $1
      possible_licenses = licenses_per_rubygems
      # If Rubygems doesn't know the license, let's try to figure it out ourselves.
      client.tree(full_repo_name, git_reference || 'master').tree.each do |twig|
        if twig.type == 'blob' && twig.path =~ /licen[sc]e.*|readme.*/i
          sap = decoded_content(client.contents(full_repo_name, :path => twig.path, :ref => git_reference || 'master').content)
          regex = LICENSE_REGEXES.detect{|r| sap.match(r)}
          if regex && match = sap.match(regex)
            possible_licenses << match['l'].strip
          elsif twig.path =~ /licen[sc]e/i
            @license_url = "#{github_url}/#{twig.path}" unless github_url.blank?
          end
        end
      end
      @licenses = possible_licenses.uniq
    end
  rescue => e
    puts "Exception: #{e}"
    puts e.backtrace
    @licenses = []
  end

  def licenses
    extract_licenses
    @licenses
  end

  def license
    extract_licenses
    [*@licenses].select{|l| l.length >= 3}.join(', ')
  end

  def license_url
    extract_licenses
    @license_url
  end

  def requestors
    @requestors ||= {}
  end

  def set_requestor(repo_name, committer_name)
    requestors[repo_name] = committer_name
  end
end

class RepoData < Struct.new(:owner, :name, :branch)
  attr_accessor :dependencies

  @@info_cache = {}
  @@gemmy_cache = {}

  GITHUB_SOURCE_REGEX = /^git@github.com:(.+).git \(at (.+)\)$/ # => https://github.com/$1/tree/$2

  def dependencies
    @dependencies ||= []
  end

  def full_name
    "#{owner}/#{name}"
  end

  def specs
    @specs ||= {}
  end

  def blame_data
    @blame_data ||= begin
      dependency_committers = dependencies.each_with_object({}){|d, h| h[d.name] = nil}
      num_dependencies = dependency_committers.keys.count
      client.commits(full_name, branch, :path => 'Gemfile').sort_by{|c| c.commit.committer.date}.reverse.each do |commit_data_hash|
        committer = commit_data_hash.commit.committer.name
        diff = client.commit(full_name, commit_data_hash.sha).files.detect{|f| f.filename == 'Gemfile'}.patch
        diff.scan(/^\+(.*)$/).flatten.collect{|l| match = l.match(Gemnasium::Parser::Patterns::GEM_CALL) and match['name']}.compact.each do |gem_name|
          if dependency_committers.key?(gem_name) && dependency_committers[gem_name].nil?
            dependency_committers[gem_name] = committer
            num_dependencies -= 1
          end
        end
        break if num_dependencies <= 0
      end
      # puts "blame_data for #{full_name}:"
      # puts dependency_committers
      dependency_committers
    end
  end

  def number_of_downloads(spec)
    versions = Gems.versions(spec.name)
    version_number = spec.version.to_s
    if versions.respond_to?(:detect) && version_data = versions.detect{|vh| vh['number'] == version_number}
      version_data['downloads_count']
    end
  end

  def gem_info(gem_name)
    @@info_cache[gem_name] ||= Gems.info(gem_name)
  end

  def github_url(spec)
    if spec.source.to_s =~ GITHUB_SOURCE_REGEX
      "http://github.com/#{$1}/tree/#{$2}"
    else
      gem_info(spec.name)['source_code_uri']
    end
  end

  def git_reference(spec)
    $2 if spec.source.to_s =~ GITHUB_SOURCE_REGEX
  end

  def make_a_gem(spec, committer=nil)
    gemmy = @@gemmy_cache[[spec.name, spec.version]] ||= Gemmy.new(
      :name => spec.name,
      :version => spec.version.to_s,
      :github_url => github_url(spec),
      :git_reference => git_reference(spec),
      :source => spec.source,
      :spec => spec,
      :downloads => number_of_downloads(spec)
    )
    gemmy.set_requestor(self.to_s, committer)
    gemmy
  end

  def refined_gems
    puts "Refining gems for #{self}"
    gems = []

    gem_groups = dependencies.each_with_object({}) do |dependency, hash|
      spec = specs[dependency.name]
      committer = nil #blame_data[dependency.name]
      if spec && gemmy = make_a_gem(spec, committer)
        gemmy.dependent_gems = spec.dependencies.collect do |dep|
          if specs[dep.name]
            make_a_gem(specs[dep.name], committer)
          else
            puts "Hm, looks like we don't have a spec for #{dep.name} for #{gemmy.name}"
          end
        end.compact
        dependency.groups.each{|group| (hash[group] ||= Set.new).merge([gemmy, *gemmy.dependent_gems])}
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
  @client ||= Octokit::Client.new(:login => ENV['GITHUB_USERNAME'], :oauth_token => ENV['GITHUB_AUTH_TOKEN'], :auto_traversal => true)
end

def repos_using_gem
  @gems ||= {}
end

def add_dependency_for(repo, dependency)
  repo.specs[dependency.name] = dependency
  (repos_using_gem[[dependency.name, dependency.version.to_s]] ||= Set.new) << repo
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
    repo_data.gemfile = Gemnasium::Parser.gemfile(decoded_content(gemfile_blob.content))
    repo_data.dependencies = repo_data.gemfile.dependencies
  else
    puts "Couldn't find a Gemfile in #{repo.full_name}@#{branch_name}"
  end

  if lock_blob
    puts "Parsing #{repo.full_name}@#{branch_name}'s Gemfile.lock"
    lockfile = Bundler::LockfileParser.new(decoded_content(lock_blob.content))
    lockfile.specs.each{|spec| add_dependency_for(repo_data, spec)}
    repo_data.lockfile = lockfile
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
  # File.open('all_repo_data.dump', 'w'){|f| f.print Marshal.dump(all_repo_data)}
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
    'License URL',
    'For Use in Medidata Products',
    'URL of Software Application',
    'Internal Repository',
    'Number of Downloads'
  ]
  sheet.add_autofilter 'A3:G3'
  gems.sort_by{|g| [g.name, g.version]}.each do |gemmy|
    sheet.add_row [
      gemmy.name,
      gemmy.version,
      '',#gemmy.requestors.values.uniq.join(', '), # Requestor
      gemmy.tap{|g| puts "#{g.name} license = #{g.license}"}.license, # License
      gemmy.license_url, # License URL
      repos_using_gem[[gemmy.name, gemmy.version]].to_a.join(', '),
      "#{gemmy.github_url.blank? ? gemmy.source : gemmy.github_url}",
      (gemmy.source && "#{gemmy.source}".include?('github.com:mdsol/')) ? 'yes' : 'no',
      gemmy.downloads
    ]
  end
end

doc = XlsxWriter::Document.new
fill_sheet(doc.add_sheet('Used_in_Released_Products'), prod_gems)
fill_sheet(doc.add_sheet('Used_Internally_at_Medidata'), dev_gems)

require 'fileutils'
FileUtils.mv doc.path, "./foss.xlsx"
doc.cleanup
