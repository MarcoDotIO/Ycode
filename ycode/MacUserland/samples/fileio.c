// Milestone A sample: file I/O through stdio and the raw descriptor calls
// (specs/macos/macos-apps.md §9.1). Ycode's own test program.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    const char *path = "/tmp/ycode-fileio.txt";
    FILE *f = fopen(path, "w");
    if (!f) { perror("fopen w"); return 1; }
    for (int i = 0; i < 100; i++) fprintf(f, "line %d\n", i);
    if (fclose(f) != 0) { perror("fclose"); return 1; }

    struct stat st;
    if (stat(path, &st) != 0) { perror("stat"); return 1; }
    printf("size %lld\n", (long long)st.st_size);

    f = fopen(path, "r");
    if (!f) { perror("fopen r"); return 1; }
    char line[64];
    int count = 0, last = -1;
    while (fgets(line, sizeof line, f)) {
        count++;
        last = atoi(line + 5);
    }
    fclose(f);
    printf("read %d lines, last %d\n", count, last);

    int fd = open(path, O_RDWR | O_APPEND);
    if (fd < 0) { perror("open"); return 1; }
    const char tail[] = "tail\n";
    if (write(fd, tail, sizeof tail - 1) != (ssize_t)(sizeof tail - 1)) { perror("write"); return 1; }
    off_t end = lseek(fd, 0, SEEK_END);
    char back[5];
    if (pread(fd, back, 4, end - 5) != 4) { perror("pread"); return 1; }
    close(fd);
    printf("end %lld, tail %.4s\n", (long long)end, back);

    if (open("/tmp/ycode-no-such-file", O_RDONLY) >= 0 || errno != ENOENT) { printf("errno %d\n", errno); return 1; }
    printf("missing file: %s\n", strerror(errno));
    if (unlink(path) != 0) { perror("unlink"); return 1; }
    printf("fileio ok\n");
    return 0;
}
