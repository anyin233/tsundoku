#include <dirent.h>
#include <errno.h>
#include <libmtp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static void print_mtp_errors(LIBMTP_mtpdevice_t *dev) {
    if (!dev) return;
    LIBMTP_Dump_Errorstack(dev);
    LIBMTP_Clear_Errorstack(dev);
}

static void free_file_list(LIBMTP_file_t *list) {
    while (list) {
        LIBMTP_file_t *next = list->next;
        LIBMTP_destroy_file_t(list);
        list = next;
    }
}

static int find_child(LIBMTP_mtpdevice_t *dev, uint32_t storage_id,
                      uint32_t parent_id, const char *name,
                      uint32_t *out_id, LIBMTP_filetype_t *out_type) {
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(dev, storage_id, parent_id);
    int found = 0;
    for (LIBMTP_file_t *f = files; f != NULL; f = f->next) {
        if (f->filename && strcmp(f->filename, name) == 0) {
            if (out_id) *out_id = f->item_id;
            if (out_type) *out_type = f->filetype;
            found = 1;
            break;
        }
    }
    free_file_list(files);
    return found;
}

static int resolve_path(LIBMTP_mtpdevice_t *dev, uint32_t storage_id,
                        const char *remote_path, int create_dirs,
                        uint32_t *out_id, LIBMTP_filetype_t *out_type) {
    uint32_t cur_id = LIBMTP_FILES_AND_FOLDERS_ROOT;
    LIBMTP_filetype_t cur_type = LIBMTP_FILETYPE_FOLDER;

    if (!remote_path || strcmp(remote_path, "/") == 0 || remote_path[0] == '\0') {
        *out_id = cur_id;
        if (out_type) *out_type = cur_type;
        return 0;
    }

    char *copy = strdup(remote_path);
    if (!copy) return -1;

    char *saveptr = NULL;
    char *tok = strtok_r(copy, "/", &saveptr);
    while (tok) {
        if (tok[0] == '\0') {
            tok = strtok_r(NULL, "/", &saveptr);
            continue;
        }
        uint32_t next_id = 0;
        LIBMTP_filetype_t next_type = LIBMTP_FILETYPE_UNKNOWN;
        if (find_child(dev, storage_id, cur_id, tok, &next_id, &next_type)) {
            cur_id = next_id;
            cur_type = next_type;
        } else if (create_dirs) {
            uint32_t parent_arg = (cur_id == LIBMTP_FILES_AND_FOLDERS_ROOT) ? 0 : cur_id;
            char *seg_dup = strdup(tok);
            if (!seg_dup) {
                free(copy);
                return -1;
            }
            next_id = LIBMTP_Create_Folder(dev, seg_dup, parent_arg, storage_id);
            free(seg_dup);
            if (next_id == 0) {
                fprintf(stderr, "error: LIBMTP_Create_Folder failed for '%s'\n", tok);
                print_mtp_errors(dev);
                free(copy);
                return -1;
            }
            cur_id = next_id;
            cur_type = LIBMTP_FILETYPE_FOLDER;
        } else {
            fprintf(stderr, "error: path segment not found: '%s' (in %s)\n", tok, remote_path);
            free(copy);
            return -1;
        }
        tok = strtok_r(NULL, "/", &saveptr);
    }

    free(copy);
    *out_id = cur_id;
    if (out_type) *out_type = cur_type;
    return 0;
}

static int cmd_ls(LIBMTP_mtpdevice_t *dev, uint32_t storage_id, const char *remote_path) {
    uint32_t target_id = 0;
    LIBMTP_filetype_t target_type = LIBMTP_FILETYPE_UNKNOWN;
    if (resolve_path(dev, storage_id, remote_path, 0, &target_id, &target_type) != 0) {
        return 1;
    }
    if (target_type != LIBMTP_FILETYPE_FOLDER) {
        printf("FILE\t%u\t%s\n", target_id, remote_path);
        return 0;
    }
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(dev, storage_id, target_id);
    for (LIBMTP_file_t *f = files; f != NULL; f = f->next) {
        const char *kind = (f->filetype == LIBMTP_FILETYPE_FOLDER) ? "DIR" : "FILE";
        printf("%s\t%u\t%llu\t%s\n",
               kind,
               f->item_id,
               (unsigned long long)f->filesize,
               f->filename ? f->filename : "");
    }
    free_file_list(files);
    return 0;
}

static int cmd_get(LIBMTP_mtpdevice_t *dev, uint32_t storage_id,
                   const char *remote_path, const char *local_path) {
    uint32_t target_id = 0;
    LIBMTP_filetype_t target_type = LIBMTP_FILETYPE_UNKNOWN;
    if (resolve_path(dev, storage_id, remote_path, 0, &target_id, &target_type) != 0) {
        return 1;
    }
    if (target_type == LIBMTP_FILETYPE_FOLDER) {
        fprintf(stderr, "error: remote path is a directory: %s\n", remote_path);
        return 1;
    }
    if (LIBMTP_Get_File_To_File(dev, target_id, local_path, NULL, NULL) != 0) {
        fprintf(stderr, "error: LIBMTP_Get_File_To_File failed for %s\n", remote_path);
        print_mtp_errors(dev);
        return 1;
    }
    printf("Downloaded %s -> %s (id=%u)\n", remote_path, local_path, target_id);
    return 0;
}

static int upload_dir_recursive(LIBMTP_mtpdevice_t *dev, uint32_t storage_id,
                                const char *local_dir, uint32_t remote_parent_id) {
    DIR *dp = opendir(local_dir);
    if (!dp) {
        fprintf(stderr, "error: opendir(%s): %s\n", local_dir, strerror(errno));
        return -1;
    }

    struct dirent *ent;
    while ((ent = readdir(dp)) != NULL) {
        const char *name = ent->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        if (strcmp(name, ".DS_Store") == 0 || strncmp(name, "._", 2) == 0) continue;

        size_t path_len = strlen(local_dir) + 1 + strlen(name) + 1;
        char *child_local = malloc(path_len);
        if (!child_local) {
            closedir(dp);
            return -1;
        }
        snprintf(child_local, path_len, "%s/%s", local_dir, name);

        struct stat st;
        if (stat(child_local, &st) != 0) {
            fprintf(stderr, "error: stat(%s): %s\n", child_local, strerror(errno));
            free(child_local);
            closedir(dp);
            return -1;
        }

        if (S_ISDIR(st.st_mode)) {
            uint32_t sub_id = 0;
            LIBMTP_filetype_t sub_type = LIBMTP_FILETYPE_UNKNOWN;
            if (find_child(dev, storage_id, remote_parent_id, name, &sub_id, &sub_type)) {
                if (sub_type != LIBMTP_FILETYPE_FOLDER) {
                    fprintf(stderr, "error: remote '%s' exists as non-folder\n", name);
                    free(child_local);
                    closedir(dp);
                    return -1;
                }
            } else {
                uint32_t parent_arg = (remote_parent_id == LIBMTP_FILES_AND_FOLDERS_ROOT) ? 0 : remote_parent_id;
                char *name_dup = strdup(name);
                sub_id = LIBMTP_Create_Folder(dev, name_dup, parent_arg, storage_id);
                free(name_dup);
                if (sub_id == 0) {
                    fprintf(stderr, "error: LIBMTP_Create_Folder(%s) failed\n", name);
                    print_mtp_errors(dev);
                    free(child_local);
                    closedir(dp);
                    return -1;
                }
            }
            if (upload_dir_recursive(dev, storage_id, child_local, sub_id) != 0) {
                free(child_local);
                closedir(dp);
                return -1;
            }
        } else if (S_ISREG(st.st_mode)) {
            uint32_t existing_id = 0;
            LIBMTP_filetype_t existing_type = LIBMTP_FILETYPE_UNKNOWN;
            if (find_child(dev, storage_id, remote_parent_id, name, &existing_id, &existing_type)) {
                if (existing_type == LIBMTP_FILETYPE_FOLDER) {
                    fprintf(stderr, "error: remote '%s' exists as folder\n", name);
                    free(child_local);
                    closedir(dp);
                    return -1;
                }
                if (LIBMTP_Delete_Object(dev, existing_id) != 0) {
                    fprintf(stderr, "error: LIBMTP_Delete_Object(%u, %s) failed\n", existing_id, name);
                    print_mtp_errors(dev);
                    free(child_local);
                    closedir(dp);
                    return -1;
                }
            }

            LIBMTP_file_t *genfile = LIBMTP_new_file_t();
            if (!genfile) {
                free(child_local);
                closedir(dp);
                return -1;
            }
            genfile->filesize = (uint64_t)st.st_size;
            genfile->filename = strdup(name);
            genfile->filetype = LIBMTP_FILETYPE_UNKNOWN;
            genfile->parent_id = (remote_parent_id == LIBMTP_FILES_AND_FOLDERS_ROOT) ? 0 : remote_parent_id;
            genfile->storage_id = storage_id;

            int rc = LIBMTP_Send_File_From_File(dev, child_local, genfile, NULL, NULL);
            uint32_t new_id = genfile->item_id;
            LIBMTP_destroy_file_t(genfile);
            if (rc != 0) {
                fprintf(stderr, "error: LIBMTP_Send_File_From_File(%s) failed\n", child_local);
                print_mtp_errors(dev);
                free(child_local);
                closedir(dp);
                return -1;
            }
            printf("Uploaded %s (%llu bytes, id=%u)\n",
                   child_local, (unsigned long long)st.st_size, new_id);
        }

        free(child_local);
    }

    closedir(dp);
    return 0;
}

static int cmd_put_dir(LIBMTP_mtpdevice_t *dev, uint32_t storage_id,
                       const char *local_dir, const char *remote_dir) {
    struct stat st;
    if (stat(local_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "error: local directory not found: %s\n", local_dir);
        return 1;
    }
    uint32_t remote_id = 0;
    LIBMTP_filetype_t remote_type = LIBMTP_FILETYPE_UNKNOWN;
    if (resolve_path(dev, storage_id, remote_dir, 1, &remote_id, &remote_type) != 0) {
        return 1;
    }
    if (remote_type != LIBMTP_FILETYPE_FOLDER) {
        fprintf(stderr, "error: remote destination is not a folder: %s\n", remote_dir);
        return 1;
    }
    return upload_dir_recursive(dev, storage_id, local_dir, remote_id) == 0 ? 0 : 1;
}

static void usage(void) {
    fprintf(stderr,
            "Usage:\n"
            "  mtp_tool ls <remote_path>\n"
            "  mtp_tool get <remote_file_path> <local_file_path>\n"
            "  mtp_tool put-dir <local_dir> <remote_dir_path>\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage();
        return 2;
    }

    const char *cmd = argv[1];
    if ((strcmp(cmd, "ls") == 0 && argc != 3) ||
        (strcmp(cmd, "get") == 0 && argc != 4) ||
        (strcmp(cmd, "put-dir") == 0 && argc != 4) ||
        (strcmp(cmd, "ls") != 0 && strcmp(cmd, "get") != 0 && strcmp(cmd, "put-dir") != 0)) {
        usage();
        return 2;
    }

    LIBMTP_Init();
    LIBMTP_raw_device_t *raw_devices = NULL;
    int num_devs = 0;
    LIBMTP_error_number_t derr = LIBMTP_Detect_Raw_Devices(&raw_devices, &num_devs);
    if (derr != LIBMTP_ERROR_NONE || num_devs <= 0 || !raw_devices) {
        fprintf(stderr, "error: no MTP device found (err=%d, count=%d)\n", (int)derr, num_devs);
        if (raw_devices) LIBMTP_FreeMemory(raw_devices);
        return 1;
    }

    int target_idx = 0;
    for (int i = 0; i < num_devs; i++) {
        if (raw_devices[i].device_entry.vendor_id == 0x1949) {
            target_idx = i;
            break;
        }
    }

    LIBMTP_mtpdevice_t *dev = LIBMTP_Open_Raw_Device_Uncached(&raw_devices[target_idx]);
    LIBMTP_FreeMemory(raw_devices);
    if (!dev) {
        fprintf(stderr, "error: failed to open MTP device\n");
        return 1;
    }

    int exit_code = 1;
    if (LIBMTP_Get_Storage(dev, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0 || !dev->storage) {
        fprintf(stderr, "error: failed to get MTP storage\n");
        print_mtp_errors(dev);
        goto cleanup;
    }

    uint32_t storage_id = dev->storage->id;
    if (strcmp(cmd, "ls") == 0) {
        exit_code = cmd_ls(dev, storage_id, argv[2]);
    } else if (strcmp(cmd, "get") == 0) {
        exit_code = cmd_get(dev, storage_id, argv[2], argv[3]);
    } else if (strcmp(cmd, "put-dir") == 0) {
        exit_code = cmd_put_dir(dev, storage_id, argv[2], argv[3]);
    }

cleanup:
    LIBMTP_Release_Device(dev);
    return exit_code;
}
