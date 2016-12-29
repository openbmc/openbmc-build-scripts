#include <stdio.h>
#include <unistd.h>
#include <errno.h>

int main(int argc, char *argv[]) {
    printf("Started C program\n");
    int status = execl("/bin/bash", "sh", "/workspace/build.sh", NULL);
    printf("Error: %i\n", errno);
    return 0;
}

