// Disk Inventory Zed - Linux signal bridge acceptance tests
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

#define _POSIX_C_SOURCE 200809L

#include "CLinuxSignals.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *message) {
    fprintf(stderr, "%s: %s\n", message, strerror(errno));
    exit(EXIT_FAILURE);
}

static void require(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(EXIT_FAILURE);
    }
}

static void alarm_probe(int signal_number) {
    (void)signal_number;
}

static void test_signal_latching_and_restoration(void) {
    struct sigaction original_alarm_action;
    struct sigaction probe_action;
    struct sigaction restored_alarm_action;
    int descriptors[2];
    int received_signal = 0;

    memset(&probe_action, 0, sizeof(probe_action));
    sigemptyset(&probe_action.sa_mask);
    probe_action.sa_handler = alarm_probe;
    if (sigaction(SIGALRM, &probe_action, &original_alarm_action) != 0) {
        fail("Could not install the alarm probe");
    }
    alarm(30);
    if (diz_install_signal_pipe(descriptors) != 0) {
        fail("Could not install the signal bridge");
    }
    if (sigaction(SIGALRM, NULL, &restored_alarm_action) != 0) {
        fail("Could not inspect the active alarm action");
    }
    require(
        restored_alarm_action.sa_handler == alarm_probe,
        "The signal bridge replaced the caller's SIGALRM action"
    );
    unsigned int remaining_alarm = alarm(0);
    require(
        remaining_alarm > 0 && remaining_alarm <= 30,
        "The signal bridge replaced the caller's active alarm"
    );
    if (kill(getpid(), SIGINT) != 0) {
        fail("Could not deliver SIGINT");
    }
    if (read(descriptors[0], &received_signal, sizeof(received_signal)) !=
        (ssize_t)sizeof(received_signal)) {
        fail("Could not read the latched signal");
    }

    require(received_signal == SIGINT, "The signal pipe did not contain SIGINT");
    require(diz_received_signal() == SIGINT, "The signal bridge did not expose SIGINT");
    require(diz_finish_signal_pipe() == SIGINT, "The signal bridge did not latch SIGINT");
    require(alarm(0) == 0, "The signal bridge unexpectedly armed SIGALRM");
    if (sigaction(SIGALRM, NULL, &restored_alarm_action) != 0) {
        fail("Could not inspect the restored alarm action");
    }
    require(
        restored_alarm_action.sa_handler == alarm_probe,
        "The prior SIGALRM action was not restored"
    );

    close(descriptors[0]);
    close(descriptors[1]);
    if (sigaction(SIGALRM, &original_alarm_action, NULL) != 0) {
        fail("Could not restore the original alarm action");
    }
}

static double elapsed_seconds(struct timespec start, struct timespec end) {
    return (double)(end.tv_sec - start.tv_sec) +
        (double)(end.tv_nsec - start.tv_nsec) / 1000000000.0;
}

static void test_watchdog_forces_exit(void) {
    int readiness_pipe[2];
    if (pipe(readiness_pipe) != 0) {
        fail("Could not create the readiness pipe");
    }

    pid_t child = fork();
    if (child < 0) {
        fail("Could not fork the watchdog probe");
    }
    if (child == 0) {
        int signal_descriptors[2];
        close(readiness_pipe[0]);
        if (diz_install_signal_pipe(signal_descriptors) != 0) {
            _exit(120);
        }
        if (write(readiness_pipe[1], "R", 1) != 1) {
            _exit(121);
        }
        close(readiness_pipe[1]);
        for (;;) {
            pause();
        }
    }

    close(readiness_pipe[1]);
    char ready = '\0';
    if (read(readiness_pipe[0], &ready, 1) != 1 || ready != 'R') {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        require(0, "The watchdog probe did not become ready");
    }
    close(readiness_pipe[0]);

    struct timespec start;
    struct timespec end;
    if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) {
        fail("Could not read the monotonic clock");
    }
    if (kill(child, SIGTERM) != 0) {
        fail("Could not deliver SIGTERM to the watchdog probe");
    }

    int status = 0;
    int completed = 0;
    const struct timespec polling_delay = {.tv_sec = 0, .tv_nsec = 100000000};
    for (int attempt = 0; attempt < 50; attempt++) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            completed = 1;
            break;
        }
        if (result < 0) {
            fail("Could not wait for the watchdog probe");
        }
        nanosleep(&polling_delay, NULL);
    }
    if (!completed) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        require(0, "The forced-exit watchdog did not terminate the stalled process");
    }
    if (clock_gettime(CLOCK_MONOTONIC, &end) != 0) {
        fail("Could not read the monotonic clock");
    }

    require(WIFEXITED(status), "The watchdog probe did not exit normally");
    require(WEXITSTATUS(status) == 128 + SIGTERM, "The watchdog returned the wrong status");
    double duration = elapsed_seconds(start, end);
    require(duration >= 0.5, "The watchdog probe exited before its grace period");
    require(duration < 5.0, "The watchdog probe exceeded its bounded grace period");
}

int main(void) {
    test_signal_latching_and_restoration();
    test_watchdog_forces_exit();
    puts("Linux signal bridge acceptance checks passed");
    return EXIT_SUCCESS;
}
