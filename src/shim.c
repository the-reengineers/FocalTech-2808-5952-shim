#define _GNU_SOURCE
#include <dlfcn.h>
#include <glib.h>

// Функция-прокси: ищет настоящую функцию в современной системе
static void* get_real_func(const char* name) {
    void *handle = dlopen("libgusb.so.2", RTLD_LAZY);
    return handle ? dlsym(handle, name) : NULL;
}

// Перехватываем запросы от сканера и пробрасываем их в свежую libgusb:
GPtrArray* g_usb_device_get_interfaces(void *device, GError **error) {
    GPtrArray* (*real_func)(void*, GError**) = get_real_func("g_usb_device_get_interfaces");
    return real_func ? real_func(device, error) : NULL;
}

guint8 g_usb_interface_get_number(void *iface) {
    guint8 (*real_func)(void*) = get_real_func("g_usb_interface_get_number");
    return real_func ? real_func(iface) : 0;
}

guint16 g_usb_device_get_release(void *device) {
    guint16 (*real_func)(void*) = get_real_func("g_usb_device_get_release");
    return real_func ? real_func(device) : 0;
}

guint8 g_usb_interface_get_protocol(void *iface) {
    guint8 (*real_func)(void*) = get_real_func("g_usb_interface_get_protocol");
    return real_func ? real_func(iface) : 0;
}

guint8 g_usb_interface_get_class(void *iface) {
    guint8 (*real_func)(void*) = get_real_func("g_usb_interface_get_class");
    return real_func ? real_func(iface) : 0;
}

guint8 g_usb_interface_get_subclass(void *iface) {
    guint8 (*real_func)(void*) = get_real_func("g_usb_interface_get_subclass");
    return real_func ? real_func(iface) : 0;
}
