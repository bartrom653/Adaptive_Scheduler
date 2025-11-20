#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>   // для delayed_work
#include <linux/jiffies.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Roman Bartusevych");
MODULE_DESCRIPTION("Adaptive CPU scheduling kernel module (sysfs + periodic load update demo)");
MODULE_VERSION("0.2");

// ----------------------
// Глобальні змінні
// ----------------------

// Рівень “підсилення” (керується з userspace через boost_level)
static int boost_level = 0;

// Псевдо-навантаження CPU (0..100), read-only з userspace
static int current_load = 0;

// Робота, яка періодично оновлює current_load
static struct delayed_work load_work;

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
        boost_level = val;
        pr_info("adaptive_sched: boost_level set to %d\n", boost_level);
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
    // Повертаємо поточне значення current_load
    return scnprintf(buf, PAGE_SIZE, "%d\n", current_load);
}

// для read-only атрибутів store = NULL
static struct kobj_attribute load_attr =
    __ATTR(current_load, 0444, load_show, NULL);

// ----------------------
// Група атрибутів sysfs
// ----------------------

static struct attribute *attrs[] = {
    &boost_attr.attr,
    &load_attr.attr,
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
    // Проста демонстрація: current_load “бігає” по колу 0..100
    current_load += 5;
    if (current_load > 100)
        current_load = 0;

    pr_debug("adaptive_sched: current_load = %d\n", current_load);

    // Перезапланувати цю ж роботу ще раз через 500 мс
    schedule_delayed_work(&load_work, msecs_to_jiffies(500));
}

// ----------------------
// init / exit
// ----------------------

static int __init adaptive_sched_init(void)
{
    int ret;

    pr_info("adaptive_sched: init\n");

    // Створюємо /sys/kernel/adaptive_sched
    adaptive_kobj = kobject_create_and_add("adaptive_sched", kernel_kobj);
    if (!adaptive_kobj) {
        pr_err("adaptive_sched: failed to create kobject\n");
        return -ENOMEM;
    }

    // Додаємо атрибути (boost_level, current_load)
    ret = sysfs_create_group(adaptive_kobj, &attr_group);
    if (ret) {
        pr_err("adaptive_sched: failed to create sysfs group\n");
        kobject_put(adaptive_kobj);
        return ret;
    }

    // Ініціалізуємо роботу для періодичного оновлення current_load
    INIT_DELAYED_WORK(&load_work, load_work_func);
    schedule_delayed_work(&load_work, msecs_to_jiffies(500));

    pr_info("adaptive_sched: sysfs interface created, work scheduled\n");
    return 0;
}

static void __exit adaptive_sched_exit(void)
{
    pr_info("adaptive_sched: exit\n");

    // Зупиняємо відкладену роботу, щоб ядро не впало
    cancel_delayed_work_sync(&load_work);

    if (adaptive_kobj) {
        sysfs_remove_group(adaptive_kobj, &attr_group);
        kobject_put(adaptive_kobj);
    }
}

module_init(adaptive_sched_init);
module_exit(adaptive_sched_exit);
