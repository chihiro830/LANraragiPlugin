package LANraragi::Plugin::Scripts::FolderToCatCO;

use strict;
use warnings;
use File::Find;
use File::Basename;
use Data::Dumper;

use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Generic qw(is_archive);
use LANraragi::Utils::Database qw(compute_id redis_encode redis_decode);
use LANraragi::Model::Category;
use LANraragi::Model::Config;

#Meta-information about your plugin.
sub plugin_info {
    return (
        name        => "Subfolders to Categories",
        type        => "script",
        namespace   => "fldr2catco",
        author      => "Difegue and chihiro",
        version     => "1.2.1",
        description => "Scan your Content Folder and automatically create Static Categories for each subfolder.<br>This Script will create a category for each subfolder with archives as direct children.",
        parameters  => [
            {
                type          => "bool",
                desc          => "Delete all your static categories before creating the ones matching your subfolders",
                default_value => "0"
            },
            {
                type          => "bool",
                desc          => "Use top level subfolders only to create categories",
                default_value => "0"
            },
            {
                type          => "string",
                desc          => "Exclude directories (comma-separated list, e.g.: thumb,temp,exclude)",
                default_value => "thumb"
            }
        ]
    );
}

sub run_script {
    shift;
    my $lrr_info = shift;
    my ( $delete_old_cats, $by_top_folder, $exclude_dirs ) = @_;
    my $logger = get_logger( "Folder2Category", "plugins" );
    my $userdir = LANraragi::Model::Config->get_userdir;

    # 处理排除目录列表
    my @exclude_list = split(/\s*,\s*/, $exclude_dirs);
    my %exclude_dirs_hash = map { $_ => 1 } @exclude_list;
    
    $logger->info("Excluding directories: " . join(", ", @exclude_list));

    my %subfolders;
    my @created_categories;
    my %existing_categories;

    # 获取Redis连接
    my $redis = LANraragi::Model::Config->get_redis;
    my $redis_config = LANraragi::Model::Config->get_redis_config;

    # 获取文件ID映射
    my %file_id_map;
    if ($redis_config->exists("LRR_FILEMAP")) {
        my %map = $redis_config->hgetall("LRR_FILEMAP");
        while (my ($file, $id) = each %map) {
            $file_id_map{$file} = $id;
        }
    }

    # 如果选择删除旧分类
    if ($delete_old_cats) {
        $logger->info("Deleting all existing static categories...");
        my @old_categories = LANraragi::Model::Category::get_static_category_list();
        foreach my $category (@old_categories) {
            my $cat_id = %{$category}{"id"};
            LANraragi::Model::Category::delete_category($cat_id);
        }
    }

    # 获取现有的静态分类
    my @categories = LANraragi::Model::Category::get_static_category_list();
    $logger->debug("Found existing categories: " . Dumper(\@categories));
    
    foreach my $category (@categories) {
        my $cat_name_raw = %{$category}{"name"};
        my $cat_name = redis_decode($cat_name_raw);
        my $cat_id = %{$category}{"id"};
        
        $logger->debug("Category name (raw): " . unpack("H*", $cat_name_raw));
        $logger->debug("Category name (decoded): " . unpack("H*", $cat_name));
        
        $existing_categories{$cat_name} = {
            id => $cat_id,
            archives => $category->{"archives"}
        };
        $logger->debug("Loaded existing category: '$cat_name' (ID: $cat_id)");
    }

    # 扫描文件夹
    find(
        {   wanted => sub {
                return if $File::Find::dir eq $userdir;
                return unless is_archive($_);
                
                # 检查是否在排除目录中
                my $current_path = $File::Find::dir;
                foreach my $exclude_dir (@exclude_list) {
                    return if $current_path =~ /\/$exclude_dir$/;
                    return if $current_path =~ /\/$exclude_dir\//;
                }

                my $dirname = $by_top_folder ? 
                    (split('/', substr($File::Find::dir, length($userdir) + 1)))[0] :
                    basename($File::Find::dir);
                
                # 添加调试信息
                $logger->debug("Directory name (raw): " . unpack("H*", $dirname));
                
                # 尝试不同的解码方式
                my $dirname_decoded = redis_decode($dirname);
                $logger->debug("Directory name (decoded): " . unpack("H*", $dirname_decoded));
                
                # 检查顶层目录是否在排除列表中
                return if exists $exclude_dirs_hash{$dirname_decoded};

                $subfolders{$dirname_decoded} //= [];
                push @{ $subfolders{$dirname_decoded} }, $_;
            },
            no_chdir    => 1,
            follow_fast => 1
        },
        $userdir
    );

    $logger->debug("Found folders with hex encoding:");
    for my $folder (keys %subfolders) {
        $logger->debug("Folder: " . unpack("H*", $folder));
    }

    # 处理每个子文件夹
    for my $folder (keys %subfolders) {
        $logger->debug("Processing folder (hex): " . unpack("H*", $folder));
        $logger->debug("Existing categories (hex):");
        for my $existing (keys %existing_categories) {
            $logger->debug("  " . unpack("H*", $existing));
        }
        
        if (exists $existing_categories{$folder}) {
            $logger->info("Found matching category for: " . unpack("H*", $folder));
        } else {
            $logger->info("No matching category found for: " . unpack("H*", $folder));
        }
        
        my $catID;
        my $processed = 0;
        my $errors = 0;
        
        if (exists $existing_categories{$folder}) {
            $logger->info("Updating existing category '$folder'");
            $catID = $existing_categories{$folder}{id};
            my $existing_archives = $existing_categories{$folder}{archives};
            my @archive_list = ref($existing_archives) eq 'ARRAY' ? @$existing_archives : ();
            
            for my $file (@{ $subfolders{$folder} }) {
                eval {
                    # 首先从文件映射中获取ID
                    my $id = $file_id_map{$file};
                    
                    # 如果映射中没有，才计算新ID
                    if (!$id) {
                        $id = compute_id($file);
                        $file_id_map{$file} = $id if $id;
                    }

                    if ($id && !grep { $_ eq $id } @archive_list) {
                        my ($success, $message) = LANraragi::Model::Category::add_to_category($catID, $id);
                        if ($success) {
                            $processed++;
                            $logger->debug("Added file $file to category $folder");
                        } else {
                            $logger->warn("Failed to add file $file: $message");
                            $errors++;
                        }
                    }
                };
                if ($@) {
                    $logger->error("Error processing file $file: $@");
                    $errors++;
                }
            }
        } else {
            $logger->info("Creating new category '$folder'");
            $catID = LANraragi::Model::Category::create_category($folder, "", 0, "");
            
            if (!$catID) {
                $logger->error("Failed to create category for folder: $folder");
                next;
            }
            
            push @created_categories, $catID;

            for my $file (@{ $subfolders{$folder} }) {
                eval {
                    my $id = $file_id_map{$file};
                    
                    if (!$id) {
                        $id = compute_id($file);
                        $file_id_map{$file} = $id if $id;
                    }

                    if ($id) {
                        my ($success, $message) = LANraragi::Model::Category::add_to_category($catID, $id);
                        if ($success) {
                            $processed++;
                            $logger->debug("Added file $file to category $folder");
                        } else {
                            $logger->warn("Failed to add file $file: $message");
                            $errors++;
                        }
                    } else {
                        $logger->warn("Could not compute ID for file: $file");
                        $errors++;
                    }
                };
                if ($@) {
                    $logger->error("Error processing file $file: $@");
                    $errors++;
                }
            }
        }
        
        $logger->info(sprintf(
            "Category '%s': Processed %d files, %d errors", 
            $folder, $processed, $errors
        ));
    }

    $redis->quit;
    $redis_config->quit;

    my $total_created = scalar @created_categories;
    $logger->info("Created $total_created new categories");
    
    return (
        created_categories => \@created_categories,
        operation_status => "Processed " . scalar(keys %subfolders) . " folders"
    );
}

1;