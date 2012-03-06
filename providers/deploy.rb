#
# Cookbook Name:: artifact
# Provider:: deploy
#
# Author:: Jamie Winsor (<jamie@vialstudios.com>)
# Copyright 2012, Riot Games
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require 'pathname'

attr_reader :release_path
attr_reader :current_path
attr_reader :shared_path
attr_reader :previous_release_path
attr_reader :artifact_root
attr_reader :artifact_filename
attr_reader :version_container_path
attr_reader :cached_tar_path
attr_reader :previous_versions

def load_current_resource
  @release_path           = @new_resource.release_path
  @current_path           = @new_resource.current_path
  @shared_path            = @new_resource.shared_path
  @artifact_root          = ::File.join(@new_resource.artifact_deploy_path, @new_resource.name)
  @version_container_path = ::File.join(@artifact_root, @new_resource.version)
  @artifact_filename      = ::File.basename(@new_resource.artifact_url)
  @cached_tar_path        = ::File.join(@version_container_path, @artifact_filename)
  @previous_release_path  = get_previous_release_path
  @previous_versions      = get_previous_versions
  @current_resource       = Chef::Resource::ArtifactDeploy.new(@new_resource.name)

  @current_resource
end

action :deploy do
  next unless new_resource.force or not deployed?

  delete_previous_versions(:keep => new_resource.keep)

  recipe_eval do
    setup_deploy_directories!
    setup_shared_directories!

    remote_file cached_tar_path do
      source new_resource.artifact_url
      owner new_resource.owner
      group new_resource.group
      backup false

      action :create_if_missing
    end

    execute "extract_artifact" do
      command "tar xzf #{cached_tar_path} -C #{new_resource.release_path}"
      user new_resource.owner
      group new_resource.group
    end

    symlink_it_up!
  end

  recipe_eval(&new_resource.before_migrate)
  recipe_eval(&new_resource.migrate) if new_resource.should_migrate
  recipe_eval(&new_resource.after_migrate)
  
  recipe_eval do
    link new_resource.current_path do
      to new_resource.release_path
    end
  end

  recipe_eval(&new_resource.restart_proc)

  recipe_eval { write_completion_token }
end

private

  def delete_previous_versions(options = {})
    keep = options[:keep] || 0
    delete_first = total = previous_versions.length

    if total == 0 || total <= keep
      return true
    end

    delete_first -= keep

    Chef::Log.info "artifact_deploy[delete_previous_versions] is deleting #{delete_first} of #{total} old versions (keeping: #{keep})"

    to_delete = previous_versions.shift(delete_first)

    to_delete.each do |version|
      delete_cached_files_for(version.basename)
      delete_release_path_for(version.basename)
      Chef::Log.info "artifact_deploy[delete_previous_versions] #{version.basename} deleted"
    end
  end

  def delete_cached_files_for(version)
    FileUtils.rm_rf ::File.join(artifact_root, version)
  end

  def delete_release_path_for(version)
    FileUtils.rm_rf ::File.join(new_resource.deploy_to, 'releases', version)
  end
  
  def deployed?
    ::File.exists?(completion_token_path)
  end

  def get_previous_release_path
    if ::File.exists?(current_path)
      ::File.readlink(current_path)
    end
  end

  def get_previous_versions
    versions = Dir[::File.join(artifact_root, '**')].collect do |v|
      Pathname.new(v)
    end

    versions.reject! { |v| v.to_s == version_container_path }

    versions.sort_by(&:mtime)
  end

  def completion_token_path
    "#{version_container_path}/deploy_complete"
  end

  def symlink_it_up!
    new_resource.symlinks.each do |key, value|
      directory "#{new_resource.shared_path}/#{key}" do
        owner new_resource.owner
        group new_resource.group
        mode '0755'
        recursive true
      end

      link "#{new_resource.release_path}/#{value}" do
        to "#{new_resource.shared_path}/#{key}"
        owner new_resource.owner
        group new_resource.group
      end
    end
  end

  def setup_deploy_directories!
    [ version_container_path, release_path, shared_path ].each do |path|
      directory path do
        owner new_resource.owner
        group new_resource.group
        mode '0755'
        recursive true
      end
    end
  end

  def setup_shared_directories!
    new_resource.shared_directories.each do |dir|
      directory "#{shared_path}/#{dir}" do
        owner new_resource.owner
        group new_resource.group
        mode '0755'
        recursive true
      end
    end
  end

  def write_completion_token
    file completion_token_path do
      content release_path
    end
  end