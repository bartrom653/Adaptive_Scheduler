#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>
#include <linux/jiffies.h>
#include <linux/pid.h>      // find_vpid, pid_task
#include <linux/sched.h>    // task_struct, set_user_nice

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Roman Bartusevych");
MODULE_DESCRIPTION("Adaptive CPU scheduling kernel module (sysfs + periodic load + PID control)");
MODULE_VERSION("0.3");

// ----------------------
// Глобальні змінні
// ----------------------

// Рівень “підсилення” (0..3), керується з userspace через boost_level
static int boost_level = 0;

// Псевдо-навантаження CPU (0..100), read-only для userspace
static int current_load = 0;

// Цільовий процес, яким керуємо (0 - немає)
static pid_t target_pid = 0;

// Робота, яка періодично оновлює current_load
static struct delayed_work load_work;

// ----------------------
// Допоміжна функція: map boost_level -> nice
// ----------------------
//
// Для простоти виберемо таку шкалу:
//  boost_level = 0 -> nice = 0   (звичайний пріоритет)
//  boost_level = 1 -> nice = -2
//  boost_level = 2 -> nice = -5
//  boost_level = 3 -> nice = -10
//
// Значення nice допускаються в діапазоні [-20, 19]

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

// ----------------------
// Допоміжна функція: застосувати boost_level до target_pid
// ----------------------

static void apply_boost_to_target(void)
{
    struct pid *pid_struct;
    struct task_struct *task;
    int new_nice;

    if (target_pid <= 0) {
        pr_info("adaptive_sched: no target_pid set, nothing to boost\n");
        return;
    }

    // Знаходимо структуру pid по значенню target_pid
    pid_struct = find_vpid(target_pid);
    if (!pid_struct) {
        pr_info("adaptive_sched: target_pid %d not found (no such pid_struct)\n", target_pid);
        return;
    }

    // Отримуємо task_struct (процес) для цього PID
    task = pid_task(pid_struct, PIDTYPE_PID);
    if (!task) {
        pr_info("adaptive_sched: target_pid %d not found (no task_struct)\n", target_pid);
        return;
    }

    // Обчислюємо нове значення nice
    new_nice = boost_to_nice(boost_level);

    pr_info("adaptive_sched: applying boost_level=%d (nice=%d) to pid=%d (comm=%s)\n",
            boost_level, new_nice, target_pid, task->comm);

    // Встановлюємо nice-процесу
    set_user_nice(task, new_nice);
}

// ----------------------
// sysfs: boost_level
// ----------------------

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

        // Після зміни boost_level одразу застосовуємо його до target_pid
        apply_boost_to_target();
    } else {
        pr_info("adaptive_sched: invalid value for boost_level\n");
    }

    return count;
}

static struct kobj_attribute boost_attr =
    __ATTR(boost_level, 0664, boost_show, boost_store);

// ----------------------
// sysfs: current_load (тільки для читання)
// ----------------------

static ssize_t load_show(struct kobject *kobj,
                         struct kobj_attribute *attr,
                         char *buf)
{
    return scnprintf(buf, PAGE_SIZE, "%d\n", current_load);
}

static struct kobj_attribute load_attr =
    __ATTR(current_load, 0444, load_show, NULL);

// ----------------------
// sysfs: target_pid (R/W)
// ----------------------

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

        // При бажанні можемо одразу застосувати поточний boost до нового PID:
        if (target_pid > 0)
            apply_boost_to_target();
    } else {
        pr_info("adaptive_sched: invalid value for target_pid\n");
    }

    return count;
}

static struct kobj_attribute target_pid_attr =
    __ATTR(target_pid, 0664, target_pid_show, target_pid_store);

// ----------------------
// Група атрибутів sysfs
// ----------------------

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

// ----------------------
// Функція, яка періодично оновлює current_load
// (поки що просто бігаємо по колу 0..100)
// ----------------------

static void load_work_func(struct work_struct *work)
{
    current_load += 5;
    if (current_load > 100)
        current_load = 0;

    pr_debug("adaptive_sched: current_load = %d\n", current_load);

    schedule_delayed_work(&load_work, msecs_to_jiffies(500));
}

// ----------------------
// init / exit
// ----------------------

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
