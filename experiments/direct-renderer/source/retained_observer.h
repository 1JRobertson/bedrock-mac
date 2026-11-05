#ifndef PRIVATE_RETAINED_OBSERVER_H
#define PRIVATE_RETAINED_OBSERVER_H
#include <stddef.h>
#include <stdint.h>
enum { RO_BIRTH=1,RO_CPU_POINTER=2,RO_UPDATE=3,RO_ALIAS=4,RO_GENERATION=5,RO_DESTROY=6,RO_STREAM_READ=7,RO_REPORT=8 };
typedef struct {uint64_t operation,root,generation,handle,length,flags,auxiliary;} ROEvent;
typedef struct {uint64_t root,generation,handle,offset,length;} RORange;
uint32_t retained_observer_event(const ROEvent *event);
void retained_observer_pass(const RORange *ranges,size_t count);
void retained_observer_report(void);
int retained_observer_diagnostics(void);
#endif
