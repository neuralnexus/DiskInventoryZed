#ifndef C_LINUX_SIGNALS_H
#define C_LINUX_SIGNALS_H

int diz_install_signal_pipe(int descriptors[2]);
int diz_received_signal(void);
int diz_finish_signal_pipe(void);

#endif
