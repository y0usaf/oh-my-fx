#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    errno = 0;
    long pid = strtol(argv[1], &end, 10);
    if (errno || !end || *end || pid <= 0 || pid > INT_MAX) return 2;
    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage)) {
        perror("proc_pid_rusage");
        return 1;
    }
    printf("{\"rss_bytes\":%" PRIu64 ",\"footprint_bytes\":%" PRIu64
           ",\"max_footprint_bytes\":%" PRIu64 "}\n",
           usage.ri_resident_size, usage.ri_phys_footprint,
           usage.ri_lifetime_max_phys_footprint);
    return 0;
}
