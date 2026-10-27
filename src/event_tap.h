#ifndef POPZLIP_EVENT_TAP_H
#define POPZLIP_EVENT_TAP_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*SelectionTriggerCallback)(double mouse_x, double mouse_y, const char *selected_text, void *user_data);
typedef void (*DismissCallback)(void *user_data);

int popzlip_start_event_monitor(SelectionTriggerCallback trigger_cb, DismissCallback dismiss_cb, void *user_data);
void popzlip_stop_event_monitor(void);
int popzlip_grab_selection(char *out_buf, int max_len);
void popzlip_set_window_frame(double x, double y, double w, double h);
bool popzlip_is_window_visible(void);
void popzlip_mark_window_visible(bool visible);
void popzlip_get_screen_size(double *out_w, double *out_h);

#ifdef __cplusplus
}
#endif

#endif
