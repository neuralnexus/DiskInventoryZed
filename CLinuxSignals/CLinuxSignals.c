// Disk Inventory Zed - async-signal-safe Linux cancellation bridge
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "CLinuxSignals.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#if ATOMIC_INT_LOCK_FREE != 2
#error "Disk Inventory Zed requires lock-free atomic int signal state"
#endif

#ifndef DIZ_SIGNAL_GRACE_SECONDS
#define DIZ_SIGNAL_GRACE_SECONDS 10U
#endif
#if DIZ_SIGNAL_GRACE_SECONDS < 1
#error "DIZ_SIGNAL_GRACE_SECONDS must be positive"
#endif

static atomic_int signal_write_descriptor = -1;
static atomic_int watchdog_write_descriptor = -1;
static atomic_int received_signal = 0;
static struct sigaction previous_interrupt_action;
static struct sigaction previous_termination_action;
static pthread_t watchdog_thread;
static int watchdog_read_descriptor = -1;
static int watchdog_thread_started = 0;

static int write_command(int descriptor, int command) {
    ssize_t result;
    do {
        result = write(descriptor, &command, sizeof(command));
    } while (result < 0 && errno == EINTR);
    return result == (ssize_t)sizeof(command) ? 0 : -1;
}

static int milliseconds_until(struct timespec deadline) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }

    time_t seconds = deadline.tv_sec - now.tv_sec;
    long nanoseconds = deadline.tv_nsec - now.tv_nsec;
    if (nanoseconds < 0) {
        seconds -= 1;
        nanoseconds += 1000000000L;
    }
    if (seconds < 0 || (seconds == 0 && nanoseconds == 0)) {
        return 0;
    }
    if (seconds >= INT_MAX / 1000) {
        return INT_MAX;
    }
    int milliseconds = (int)(seconds * 1000);
    milliseconds += (int)((nanoseconds + 999999L) / 1000000L);
    return milliseconds;
}

static void *run_watchdog(void *context) {
    (void)context;
    struct pollfd descriptor = {
        .fd = watchdog_read_descriptor,
        .events = POLLIN,
        .revents = 0
    };
    int termination_signal = 0;

    while (termination_signal == 0) {
        int poll_result = poll(&descriptor, 1, -1);
        if (poll_result < 0 && errno == EINTR) {
            continue;
        }
        if (poll_result <= 0 || (descriptor.revents & (POLLERR | POLLNVAL)) != 0) {
            _exit(128 + SIGABRT);
        }
        if ((descriptor.revents & POLLIN) != 0) {
            int command = 0;
            ssize_t read_result = read(descriptor.fd, &command, sizeof(command));
            if (read_result == (ssize_t)sizeof(command)) {
                if (command == 0) {
                    return NULL;
                }
                termination_signal = command;
            } else if (read_result < 0 && (errno == EINTR || errno == EAGAIN)) {
                continue;
            } else {
                _exit(128 + SIGABRT);
            }
        }
    }

    struct timespec deadline;
    if (clock_gettime(CLOCK_MONOTONIC, &deadline) != 0) {
        _exit(128 + termination_signal);
    }
    deadline.tv_sec += DIZ_SIGNAL_GRACE_SECONDS;

    while (1) {
        int timeout = milliseconds_until(deadline);
        if (timeout == 0) {
            _exit(128 + termination_signal);
        }
        descriptor.revents = 0;
        int poll_result = poll(&descriptor, 1, timeout);
        if (poll_result == 0) {
            _exit(128 + termination_signal);
        }
        if (poll_result < 0 && errno == EINTR) {
            continue;
        }
        if (poll_result < 0 || (descriptor.revents & (POLLERR | POLLNVAL)) != 0) {
            _exit(128 + termination_signal);
        }
        if ((descriptor.revents & POLLIN) != 0) {
            int command = 0;
            ssize_t read_result = read(descriptor.fd, &command, sizeof(command));
            if (read_result == (ssize_t)sizeof(command) && command == 0) {
                return NULL;
            }
            if (read_result < 0 && (errno == EINTR || errno == EAGAIN)) {
                continue;
            }
            if (read_result != (ssize_t)sizeof(command)) {
                _exit(128 + termination_signal);
            }
        }
    }
}

static void stop_watchdog(void) {
    int descriptor = atomic_exchange(&watchdog_write_descriptor, -1);
    if (descriptor >= 0) {
        (void)write_command(descriptor, 0);
    }
    if (watchdog_thread_started) {
        (void)pthread_join(watchdog_thread, NULL);
        watchdog_thread_started = 0;
    }
}

static void handle_signal(int signal_number) {
    int expected_signal = 0;
    if (!atomic_compare_exchange_strong(&received_signal, &expected_signal, signal_number)) {
        _exit(128 + signal_number);
    }

    int saved_errno = errno;
    int descriptor = atomic_load(&signal_write_descriptor);
    if (descriptor < 0) {
        _exit(128 + signal_number);
    }

    if (write_command(descriptor, signal_number) != 0) {
        _exit(128 + signal_number);
    }

    descriptor = atomic_load(&watchdog_write_descriptor);
    if (descriptor < 0 || write_command(descriptor, signal_number) != 0) {
        _exit(128 + signal_number);
    }

    errno = saved_errno;
}

#if !defined(__linux__)
static int set_descriptor_flags(int descriptor) {
    int status_flags = fcntl(descriptor, F_GETFL);
    if (status_flags < 0 || fcntl(descriptor, F_SETFL, status_flags | O_NONBLOCK) < 0) {
        return -1;
    }

    int descriptor_flags = fcntl(descriptor, F_GETFD);
    if (descriptor_flags < 0 || fcntl(descriptor, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) {
        return -1;
    }
    return 0;
}
#endif

static int create_signal_pipe(int descriptors[2]) {
#if defined(__linux__)
    return pipe2(descriptors, O_NONBLOCK | O_CLOEXEC);
#else
    if (pipe(descriptors) != 0) {
        return -1;
    }
    if (set_descriptor_flags(descriptors[0]) == 0 &&
        set_descriptor_flags(descriptors[1]) == 0) {
        return 0;
    }

    int saved_errno = errno;
    close(descriptors[0]);
    close(descriptors[1]);
    descriptors[0] = -1;
    descriptors[1] = -1;
    errno = saved_errno;
    return -1;
#endif
}

int diz_install_signal_pipe(int descriptors[2]) {
    if (descriptors == NULL) {
        errno = EINVAL;
        return -1;
    }

    descriptors[0] = -1;
    descriptors[1] = -1;
    if (sigaction(SIGINT, NULL, &previous_interrupt_action) != 0 ||
        sigaction(SIGTERM, NULL, &previous_termination_action) != 0 ||
        create_signal_pipe(descriptors) != 0) {
        return -1;
    }

    int watchdog_descriptors[2] = {-1, -1};
    if (create_signal_pipe(watchdog_descriptors) != 0) {
        int saved_errno = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        descriptors[0] = -1;
        descriptors[1] = -1;
        errno = saved_errno;
        return -1;
    }

    struct sigaction termination_action;
    memset(&termination_action, 0, sizeof(termination_action));
    sigemptyset(&termination_action.sa_mask);
    sigaddset(&termination_action.sa_mask, SIGINT);
    sigaddset(&termination_action.sa_mask, SIGTERM);
    termination_action.sa_handler = handle_signal;

    atomic_store(&received_signal, 0);
    atomic_store(&signal_write_descriptor, descriptors[1]);
    watchdog_read_descriptor = watchdog_descriptors[0];
    atomic_store(&watchdog_write_descriptor, watchdog_descriptors[1]);
    int thread_result = pthread_create(&watchdog_thread, NULL, run_watchdog, NULL);
    if (thread_result != 0) {
        atomic_store(&signal_write_descriptor, -1);
        atomic_store(&watchdog_write_descriptor, -1);
        close(descriptors[0]);
        close(descriptors[1]);
        close(watchdog_descriptors[0]);
        close(watchdog_descriptors[1]);
        descriptors[0] = -1;
        descriptors[1] = -1;
        watchdog_read_descriptor = -1;
        errno = thread_result;
        return -1;
    }
    watchdog_thread_started = 1;
    if (sigaction(SIGINT, &termination_action, NULL) != 0) {
        int saved_errno = errno;
        atomic_store(&signal_write_descriptor, -1);
        stop_watchdog();
        close(descriptors[0]);
        close(descriptors[1]);
        close(watchdog_descriptors[0]);
        close(watchdog_descriptors[1]);
        descriptors[0] = -1;
        descriptors[1] = -1;
        watchdog_read_descriptor = -1;
        errno = saved_errno;
        return -1;
    }
    if (sigaction(SIGTERM, &termination_action, NULL) != 0) {
        int saved_errno = errno;
        atomic_store(&signal_write_descriptor, -1);
        sigaction(SIGINT, &previous_interrupt_action, NULL);
        stop_watchdog();
        // A concurrently running handler may still hold either descriptor.
        // Installation failure terminates the CLI, so process exit closes them.
        errno = saved_errno;
        return -1;
    }
    return 0;
}

int diz_finish_signal_pipe(void) {
    // Keep the descriptors open until process exit: a handler that loaded the
    // write descriptor before disarming may still be completing write().
    atomic_store(&signal_write_descriptor, -1);
    sigaction(SIGINT, &previous_interrupt_action, NULL);
    sigaction(SIGTERM, &previous_termination_action, NULL);
    stop_watchdog();
    return atomic_load(&received_signal);
}

int diz_received_signal(void) {
    return atomic_load(&received_signal);
}
