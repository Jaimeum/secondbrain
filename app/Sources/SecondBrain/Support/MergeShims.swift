// MERGE: delete this whole file once the project and meetings branches land. It only lets the shell branch build
// against the c3d9f25 types:
// - v05/project's `ProjectTab` has `case content, tasks, ask, graph` (here the Contenido tab is still `.wiki`);
// - v05/meetings' `MeetingSegment` has `case past` (Anteriores), used by the `meetings-past` snapshot.
extension ProjectTab {
    static var content: ProjectTab { .wiki }
}

extension MeetingSegment {
    static var past: MeetingSegment { .upcoming }
}
