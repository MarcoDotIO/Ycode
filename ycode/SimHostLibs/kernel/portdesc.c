/*
 * portdesc.c - names of the special-port slots (Ycode original code).
 *
 *   const char *mach_host_special_port_description(int which);
 *   const char *mach_task_special_port_description(int which);
 *   const char *mach_thread_special_port_description(int which);
 *   int mach_host_special_port_for_id(const char *id);
 *   int mach_task_special_port_for_id(const char *id);
 *   int mach_thread_special_port_for_id(const char *id);
 *
 * Behavior (xnu libsyscall/mach/mach/port_descriptions.h, level 1): a
 * description is a short human-readable label for a slot number (NULL for
 * a number out of range or a slot without one); "for_id" maps the macro
 * name of a slot ("TASK_BOOTSTRAP_PORT") to its number, or returns -1 with
 * errno EINVAL (NULL id) or ENOENT (unknown). The slot numbers are the
 * public <mach/{host,task,thread}_special_ports.h> values. launchctl
 * prints the task descriptions in its domain and service output.
 */
#include "yc_kernel.h"

YC_HIDDEN void __ycode_set_errno(int value);

struct yc_port_label {
    int which;
    const char *description;
    const char *id;
};

static const struct yc_port_label yc_host_labels[] = {
    {1, "host (restricted)", "HOST_PORT"},
    {2, "host private (restricted)", "HOST_PRIV_PORT"},
    {3, "I/O main (restricted)", "HOST_IO_MAIN_PORT"},
    {8, "dynamic pager", "HOST_DYNAMIC_PAGER_PORT"},
    {9, "audit control", "HOST_AUDIT_CONTROL_PORT"},
    {10, "user notification", "HOST_USER_NOTIFICATION_PORT"},
    {11, "automounter", "HOST_AUTOMOUNTD_PORT"},
    {12, "lockd", "HOST_LOCKD_PORT"},
    {13, "ktrace background notification", "HOST_KTRACE_BACKGROUND_PORT"},
    {14, "seatbelt", "HOST_SEATBELT_PORT"},
    {15, "kextd", "HOST_KEXTD_PORT"},
    {16, "launchctl", "HOST_LAUNCHCTL_PORT"},
    {17, "fairplay", "HOST_UNFREED_PORT"},
    {18, "amfi", "HOST_AMFID_PORT"},
    {19, "gssd", "HOST_GSSD_PORT"},
    {20, "telemetry", "HOST_TELEMETRY_PORT"},
    {21, "atm notification", "HOST_ATM_NOTIFICATION_PORT"},
    {22, "coalition notification", "HOST_COALITION_PORT"},
    {23, "sysdiagnose notification", "HOST_SYSDIAGNOSE_PORT"},
    {24, "XPC exception", "HOST_XPC_EXCEPTION_PORT"},
    {25, "container manager", "HOST_CONTAINERD_PORT"},
    {26, "node", "HOST_NODE_PORT"},
    {27, "resource notify", "HOST_RESOURCE_NOTIFY_PORT"},
    {28, "closured", "HOST_CLOSURED_PORT"},
    {29, "syspolicyd", "HOST_SYSPOLICYD_PORT"},
    {30, "filecoordinationd", "HOST_FILECOORDINATIOND_PORT"},
    {31, "fairplayd", YC_NULL},
    {32, "I/O compression stats", YC_NULL},
    {33, "memory error stats", YC_NULL},
    {34, "managedappdistributiond", YC_NULL},
    {35, "doubleagentd", YC_NULL},
};

static const struct yc_port_label yc_task_labels[] = {
    {1, "kernel", "TASK_KERNEL_PORT"},
    {2, "host", "TASK_HOST_PORT"},
    {3, "name", "TASK_NAME_PORT"},
    {4, "bootstrap", "TASK_BOOTSTRAP_PORT"},
    {5, "inspect", "TASK_INSPECT_PORT"},
    {6, "read", "TASK_READ_PORT"},
    {9, "access", "TASK_ACCESS_PORT"},
    {10, "debug control", "TASK_DEBUG_CONTROL_PORT"},
    {11, "resource notify", "TASK_RESOURCE_NOTIFY_PORT"},
};

static const struct yc_port_label yc_thread_labels[] = {
    {1, "kernel", "THREAD_KERNEL_PORT"},
    {2, "inspect", "THREAD_INSPECT_PORT"},
    {3, "read", "THREAD_READ_PORT"},
};

#define YC_COUNT(a) ((int)(sizeof(a) / sizeof((a)[0])))

static const char *yc_label_for(const struct yc_port_label *labels, int count, int which)
{
    for (int i = 0; i < count; i++)
        if (labels[i].which == which)
            return labels[i].description;
    return YC_NULL;
}

static int yc_same(const char *a, const char *b)
{
    while (*a != 0 && *a == *b) {
        a++;
        b++;
    }
    return *a == *b;
}

static int yc_slot_for(const struct yc_port_label *labels, int count, const char *id)
{
    if (id == YC_NULL) {
        __ycode_set_errno(22); /* EINVAL */
        return -1;
    }
    for (int i = 0; i < count; i++)
        if (labels[i].id != YC_NULL && yc_same(labels[i].id, id))
            return labels[i].which;
    __ycode_set_errno(2); /* ENOENT */
    return -1;
}

YC_EXPORT const char *mach_host_special_port_description(int which)
{
    return yc_label_for(yc_host_labels, YC_COUNT(yc_host_labels), which);
}

YC_EXPORT const char *mach_task_special_port_description(int which)
{
    return yc_label_for(yc_task_labels, YC_COUNT(yc_task_labels), which);
}

YC_EXPORT const char *mach_thread_special_port_description(int which)
{
    return yc_label_for(yc_thread_labels, YC_COUNT(yc_thread_labels), which);
}

YC_EXPORT int mach_host_special_port_for_id(const char *id)
{
    return yc_slot_for(yc_host_labels, YC_COUNT(yc_host_labels), id);
}

YC_EXPORT int mach_task_special_port_for_id(const char *id)
{
    return yc_slot_for(yc_task_labels, YC_COUNT(yc_task_labels), id);
}

YC_EXPORT int mach_thread_special_port_for_id(const char *id)
{
    return yc_slot_for(yc_thread_labels, YC_COUNT(yc_thread_labels), id);
}
