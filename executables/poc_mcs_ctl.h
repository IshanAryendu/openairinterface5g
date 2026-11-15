// Local PoC patch (runtime-mcs-patch.sh): run-time MCS control + sender statistics shared with user space.
#ifndef POC_MCS_CTL_H
#define POC_MCS_CTL_H
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#define POC_MCS_CTL_PATH "/dev/shm/sl-mcs-ctl"
#define POC_MCS_CTL_MAGIC 0x314D4C53u
typedef struct {
  uint32_t magic;
  volatile int32_t force_mcs; // written by the controller: -1 = modem decides, 0..28 = use this MCS
  int32_t mcs_in_use;
  int32_t mcs_modem;
  int32_t cqi;
  uint32_t sched_count;
  uint64_t rounds[4];
  uint64_t errors;
  uint64_t total_bytes;
  volatile int32_t tx_limit; // written by the controller: most PSSCH transmissions per second, 0 = no cap
  int32_t reserved;
} poc_mcs_ctl_t;
// Include this header in ONE .c file only (nr_slsch_scheduler.c): the mapping is created on first use.
static inline poc_mcs_ctl_t *poc_mcs_ctl(void)
{
  static poc_mcs_ctl_t *p = NULL;
  static int tried = 0;
  if (!tried) {
    tried = 1;
    const char *path = getenv("SL_MCS_CTL") ? getenv("SL_MCS_CTL") : POC_MCS_CTL_PATH;
    unlink(path); // a fresh file per modem run (the old one may belong to another user)
    int fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0666);
    if (fd >= 0) {
      if (fchmod(fd, 0666) == 0 && ftruncate(fd, 4096) == 0) {
        void *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (m != MAP_FAILED) {
          p = (poc_mcs_ctl_t *)m;
          p->force_mcs = -1;
          p->magic = POC_MCS_CTL_MAGIC;
        }
      }
      close(fd);
    }
    LOG_I(NR_MAC, "PoC patch: run-time MCS control file %s %s\n", path, p ? "ready" : "NOT available");
  }
  return p;
}
#endif
