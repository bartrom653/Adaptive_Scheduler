#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>
#include <linux/jiffies.h>
#include <linux/pid.h>        // find_vpid, pid_task
#include <linux/sched.h>      // task_struct, set_user_nice
#include <linux/kernel_stat.h>
#include <linux/sched/loadavg.h>
#include <linux/sched/cputime.h>
#include <linux/tick.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Roman Bartusevych");
MODULE_DESCRIPTION("Adaptive CPU scheduling kernel module (sysfs + real CPU load + PID control)");
MODULE_VERSION("0.4");

/*
 * ----------------------
 * Global variables
 * ----------------------
 */

// Boost level (0..3), controlled from userspace via boost_level sysfs attribute
static int boost_level = 0;

// Current CPU load (0..100%), read-only for userspace
static int current_load = 0;

// Target process that will be controlled by this module (0 = not set)
static pid_t target_pid = 0;

// Work item that periodically updates current_load
static struct delayed_work load_work;

// Previous values used for CPU load delta calculations
static u64 prev_idle = 0;
static u64 prev_total = 0;

/*
 * ----------------------
 * Helper: map boost_level -> nice
 * ----------------------
 *
 *  boost_level = 0 -> nice = 0   (default priority)
 *  boost_level = 1 -> nice = -2  (slightly increased priority)
 *  boost_level = 2 -> nice = -5  (higher priority)
 *  boost_level = 3 -> nice = -10 (aggressive boost)
 */

static int boost_to_nice(int boost)
{
    switch (boost) {
    case 0:
        return 0;
    case 1:
        return -2;
    case 2:
        return -5;
    case 3:
    default:
        return -10;
    }
}

/*
 * ----------------------
 * Helper: compute real CPU load (%) using kernel cpustat
 * ----------------------
 *
 * Method: compare per-CPU usage counters since the last sample.
 * CPU load = (busy_time / total_time) * 100
 */

static int get_cpu_load(int cpu)
{
    struct kernel_cpustat *kcpustat_ptr;
    u64 user, nice, system, idle, iowait, irq, softirq, steal;
    u64 idle_all, total;
    u64 diff_idle, diff_total;

    kcpustat_ptr = &kcpustat_cpu(cpu);

    user    = kcpustat_ptr->cpustat[CPUTIME_USER];
    nice    = kcpustat_ptr->cpustat[CPUTIME_NICE];
    system  = kcpustat_ptr->cpustat[CPUTIME_SYSTEM];
    idle    = kcpustat_ptr->cpustat[CPUTIME_IDLE];
    iowait  = kcpustat_ptr->cpustat[CPUTIME_IOWAIT];
    irq     = kcpustat_ptr->cpustat[CPUTIME_IRQ];
    softirq = kcpustat_ptr->cpustat[CPUTIME_SOFTIRQ];
    steal   = kcpustat_ptr->cpustat[CPUTIME_STEAL];

    idle_all = idle + iowait;
    total = user + nice + system + idle_all + irq + softirq + steal;

    // First call – just initialize previous values
    if (prev_total == 0) {
        prev_total = total;
        prev_idle  = idle_all;
        return 0;
    }

    diff_total = total - prev_total;
    diff_idle  = idle_all - prev_idle;

    prev_total = total;
    prev_idle  = idle_all;

    if (diff_total == 0)
        return 0;

    // load% = busy / total * 100
    return (int)(((diff_total - diff_idle) * 100) / diff_total);
}

/*
 * ----------------------
 * Helper: apply boost_level to target_pid
 * ----------------------
 *
 * This function adjusts the nice value of the target process
 * according to the current boost_level.
 */

static void apply_boost_to_target(void)
{
    struct pid *pid_struct;
    struct task_struct *task;
    int new_nice;

    if (target_pid <= 0) {
        pr_info("adaptive_sched: no target_pid set, nothing to boost\n");
        return;
    }

    pid_struct = find_vpid(target_pid);
    if (!pid_struct) {
        pr_info("adaptive_sched: target_pid %d not found (no pid_struct)\n",
                target_pid);
        return;
    }

    task = pid_task(pid_struct, PIDTYPE_PID);
    if (!task) {
        pr_info("adaptive_sched: target_pid %d not found (no task_struct)\n",
                target_pid);
        return;
    }

    new_nice = boost_to_nice(boost_level);

    pr_info("adaptive_sched: applying boost_level=%d (nice=%d) to pid=%d (comm=%s)\n",
            boost_level, new_nice, target_pid, task->comm);

    set_user_nice(task, new_nice);
}

/*
 * ----------------------
 * sysfs: boost_level
 * ----------------------
 */

static ssize_t boost_show(struct kobject *kobj,
                          struct kobj_attribute *attr,
                          char *buf)
{
    return scnprintf(buf, PAGE_SIZE, "%d\n", boost_level);
}

static ssize_t boost_store(struct kobject *kobj,
                           struct kobj_attribute *attr,
                           const char *buf,
                           size_t count)
{
    int val;

    if (kstrtoint(buf, 10, &val) == 0) {
        if (val < 0)
            val = 0;
        if (val > 3)
            val = 3;

        boost_level = val;
        pr_info("adaptive_sched: boost_level set to %d\n", boost_level);

        apply_boost_to_target();
    } else {
        pr_info("adaptive_sched: invalid value for boost_level\n");
    }

    return count;
}

static struct kobj_attribute boost_attr =
    __ATTR(boost_level, 0664, boost_show, boost_store);

/*
 * ----------------------
 * sysfs: current_load (read-only)
 * ----------------------
 */

static ssize_t load_show(struct kobject *kobj,
                         struct kobj_attribute *attr,
                         char *buf)
{
    return scnprintf(buf, PAGE_SIZE, "%d\n", current_load);
}

static struct kobj_attribute load_attr =
    __ATTR(current_load, 0444, load_show, NULL);

/*
 * ----------------------
 * sysfs: target_pid (R/W)
 * ----------------------
 */

static ssize_t target_pid_show(struct kobject *kobj,
                               struct kobj_attribute *attr,
                               char *buf)
{
    return scnprintf(buf, PAGE_SIZE, "%d\n", target_pid);
}

static ssize_t target_pid_store(struct kobject *kobj,
                                struct kobj_attribute *attr,
                                const char *buf,
                                size_t count)
{
    pid_t pid_val;

    if (kstrtoint(buf, 10, &pid_val) == 0) {
        if (pid_val < 0)
            pid_val = 0;

        target_pid = pid_val;
        pr_info("adaptive_sched: target_pid set to %d\n", target_pid);

        if (target_pid > 0)
            apply_boost_to_target();
    } else {
        pr_info("adaptive_sched: invalid value for target_pid\n");
    }

    return count;
}

static struct kobj_attribute target_pid_attr =
    __ATTR(target_pid, 0664, target_pid_show, target_pid_store);

/*
 * ----------------------
 * sysfs attributes group
 * ----------------------
 */

static struct attribute *attrs[] = {
    &boost_attr.attr,
    &load_attr.attr,
    &target_pid_attr.attr,
    NULL,
};

static const struct attribute_group attr_group = {
    .attrs = attrs,
};

static struct kobject *adaptive_kobj;

/*
 * ----------------------
 * Workqueue: periodic CPU load update
 * ----------------------
 */

static void load_work_func(struct work_struct *work)
{
    // For now we measure only CPU0. Later this can be extended to
    // an average or maximum across all CPUs.
    current_load = get_cpu_load(0);

    if (current_load < 0)
        current_load = 0;
    if (current_load > 100)
        current_load = 100;

    pr_debug("adaptive_sched: CPU0 load = %d%%\n", current_load);

    schedule_delayed_work(&load_work, msecs_to_jiffies(500));
}

/*
 * ----------------------
 * Module init / exit
 * ----------------------
 */

static int __init adaptive_sched_init(void)
{
    int ret;

    pr_info("adaptive_sched: init\n");

    adaptive_kobj = kobject_create_and_add("adaptive_sched", kernel_kobj);
    if (!adaptive_kobj) {
        pr_err("adaptive_sched: failed to create kobject\n");
        return -ENOMEM;
    }

    ret = sysfs_create_group(adaptive_kobj, &attr_group);
    if (ret) {
        pr_err("adaptive_sched: failed to create sysfs group\n");
        kobject_put(adaptive_kobj);
        return ret;
    }

    INIT_DELAYED_WORK(&load_work, load_work_func);
    schedule_delayed_work(&load_work, msecs_to_jiffies(500));

    pr_info("adaptive_sched: sysfs interface created, work scheduled\n");
    return 0;
}

static void __exit adaptive_sched_exit(void)
{
    pr_info("adaptive_sched: exit\n");

    cancel_delayed_work_sync(&load_work);

    if (adaptive_kobj) {
        sysfs_remove_group(adaptive_kobj, &attr_group);
        kobject_put(adaptive_kobj);
    }
}

module_init(adaptive_sched_init);
module_exit(adaptive_sched_exit);
