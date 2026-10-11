#ifndef TOBII_NATIVE_H
#define TOBII_NATIVE_H

#include <stdint.h>

typedef void (*TobiiGazeCallback)(
    double x,
    double y,
    uint32_t left_valid,
    uint32_t right_valid
);

int32_t tobii_open(void);
int32_t tobii_step(void);
void tobii_close(void);
void tobii_set_gaze_callback(TobiiGazeCallback callback);

#endif
