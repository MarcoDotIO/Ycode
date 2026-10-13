// csprobe: our probe: csops status flags and identity of processes by pid
// (pid 0 = self), and of the process found by name via proc_listallpids.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
// libproc.h is not in the iOS SDK; the functions are in libSystem (public on macOS).
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int csops(pid_t pid, unsigned int ops, void *addr, size_t size);
static void show(pid_t pid) {
  uint32_t st = 0; int r = csops(pid, 0, &st, 4);
  char path[4096] = ""; proc_pidpath(pid, path, sizeof path);
  unsigned char id[512] = {0}; int r2 = csops(pid, 11, id, sizeof id);
  unsigned char hdr[8]; int r3 = csops(pid, 7, hdr, 8); int e3 = errno;
  printf("pid %d status %#x (r %d) identity %s (r %d) ents-probe r %d errno %d len %u path %s\n", pid, st, r, r2 == 0 ? (char *)id + 8 : "-", r2, r3, e3,
         (unsigned)(hdr[4] << 24 | hdr[5] << 16 | hdr[6] << 8 | hdr[7]), path);
}
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (argv[i][0] >= '0' && argv[i][0] <= '9') { show(atoi(argv[i])); continue; }
    int pids[4096]; int n = proc_listallpids(pids, sizeof pids);
    for (int k = 0; k < n; k++) { char name[256] = ""; proc_name(pids[k], name, sizeof name); if (!strcmp(name, argv[i])) show(pids[k]); }
  }
}
