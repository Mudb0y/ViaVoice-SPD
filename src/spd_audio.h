/*
 * spd_audio.h - Minimal audio definitions for standalone module build
 * Based on speech-dispatcher's spd_audio.h
 */

#ifndef __SPD_AUDIO_H
#define __SPD_AUDIO_H

/* Audio format: endianness */
typedef enum { SPD_AUDIO_LE = 0, SPD_AUDIO_BE = 1 } AudioFormat;

/* Audio track structure */
typedef struct {
    int bits;           /* bits per sample (8 or 16) */
    int num_channels;   /* number of channels (1=mono, 2=stereo) */
    int sample_rate;    /* sample rate in Hz */
    int num_samples;    /* number of samples */
    signed short *samples;  /* sample data */
} AudioTrack;

#endif /* __SPD_AUDIO_H */
