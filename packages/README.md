# Package sources

Each folder here is the source of one QAFlow package exactly as it is
published on pub.dev:

- [`qaflow_protocol`](qaflow_protocol): wire types shared by the agent and the
  engine ([pub.dev](https://pub.dev/packages/qaflow_protocol))
- [`qaflow_agent`](qaflow_agent): the in-app agent, a Flutter package
  ([pub.dev](https://pub.dev/packages/qaflow_agent))
- [`qaflow`](qaflow): the engine and the `qa` command
  ([pub.dev](https://pub.dev/packages/qaflow))

They are copied from each release's published archive, so they change only
when a new version is published. Development happens in a separate, private
repository, so pull requests against these folders can't be merged as they
are. Issues are welcome on
[this repository](https://github.com/dmtorks/qaflow/issues), including bugs
you track down to a line here.

The pubspecs keep `resolution: workspace` as published: in the private
repository the packages build together in one pub workspace. To build one on
its own, remove that line.
