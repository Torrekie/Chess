/* Private, independently owned runtime for an embedded Sjeng session. */
#ifndef MBC_IOS_SJENG_H
#define MBC_IOS_SJENG_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MBCIOSjengSession MBCIOSjengSession;

/* Run takes ownership of both descriptors. Destroy follows Run/thread join. */
MBCIOSjengSession *MBCIOSjengCreate(int inputFD, int outputFD,
                                  const char *workingDirectory);
int MBCIOSjengRun(MBCIOSjengSession *session);
void MBCIOSjengRequestStop(MBCIOSjengSession *session);
void MBCIOSjengDestroy(MBCIOSjengSession *session);

#ifdef __cplusplus
}
#endif
#endif
