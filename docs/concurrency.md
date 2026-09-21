# Concurrency

Tasks, threads, channels, pools, and safe shared numbers are library tools. A function keeps the same shape even when it pauses; FOO has no `async` or `await` words.

Structured scopes join children before releasing borrowed storage:

```iv
constant group is task scope.
task spawn group worker with value.
task wait for group.
```

Channels pass values safely between workers. Two workers must not change the same value at once unless they use a lock or a safe shared-number operation. The library chooses the operating-system waiting method internally; FOO programs do not handle those operating-system objects directly.

## One worker

Start with one task and wait for its result:

```iv
constant task is spawn work with item.
constant result is wait for task.
```

The task is joined before its scope ends, so data borrowed from that scope remains valid.

## Two workers and a channel

```iv
constant channel is task channel of text.
spawn producer with channel.
spawn consumer with channel.
close channel.
```

The channel owns the hand-off. The producer gives text to the channel and the consumer receives it.
