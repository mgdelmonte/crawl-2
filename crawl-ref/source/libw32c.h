#pragma once

void w32_cancel_waiting_for_input();
void w32_inject_key(int vk, int ch);

bool in_headless_mode();
void enter_headless_mode();
