/// Priority level for task scheduling.
enum TaskPriority {
  low(0),
  normal(1),
  high(2),
  critical(3);

  final int value;
  const TaskPriority(this.value);
}
