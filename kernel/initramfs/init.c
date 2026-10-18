/* Minimal init for Surface Duo 2 bring-up.
 *
 * Exists only to prove the USB CDC-ACM console works end to end. A kernel with
 * no init panics, and a panic does print, but it leaves the gadget torn down
 * immediately and tells us nothing about whether the console is usable. This
 * stays alive instead, so the port can be observed rather than inferred.
 */
#include <stdio.h>
#include <unistd.h>
#include <sys/mount.h>
#include <fcntl.h>

int main(void)
{
    mount("proc",  "/proc",  "proc",  0, NULL);
    mount("sysfs", "/sys",   "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) { dup2(fd, 0); dup2(fd, 1); dup2(fd, 2); }

    printf("\n");
    printf("=====================================================\n");
    printf(" LUMA DUO2 BRING-UP INIT -- USB CONSOLE IS ALIVE\n");
    printf("=====================================================\n");
    fflush(stdout);

    for (unsigned long i = 0; ; i++) {
        printf("[duo2-init] alive, tick %lu\n", i);
        fflush(stdout);
        sleep(5);
    }
    return 0;
}
