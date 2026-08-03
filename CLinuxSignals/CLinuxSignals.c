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
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

#if ATOMIC_INT_LOCK_FREE != 2
#error "Disk Inventory Zed requires lock-free atomic int signal state"
#endif

static atomic_int signal_write_descriptor = -1;
static atomic_int received_signal = 0;
static struct sigaction previous_interrupt_action;
static struct sigaction previous_termination_action;

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

    ssize_t result;
    do {
        result = write(descriptor, &signal_number, sizeof(signal_number));
    } while (result < 0 && errno == EINTR);
    if (result != sizeof(signal_number)) {
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

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGINT);
    sigaddset(&action.sa_mask, SIGTERM);
    action.sa_handler = handle_signal;
    action.sa_flags = SA_RESTART;

    atomic_store(&received_signal, 0);
    atomic_store(&signal_write_descriptor, descriptors[1]);
    if (sigaction(SIGINT, &action, NULL) != 0) {
        int saved_errno = errno;
        atomic_store(&signal_write_descriptor, -1);
        close(descriptors[0]);
        close(descriptors[1]);
        descriptors[0] = -1;
        descriptors[1] = -1;
        errno = saved_errno;
        return -1;
    }
    if (sigaction(SIGTERM, &action, NULL) != 0) {
        int saved_errno = errno;
        atomic_store(&signal_write_descriptor, -1);
        sigaction(SIGINT, &previous_interrupt_action, NULL);
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
    return atomic_load(&received_signal);
}
