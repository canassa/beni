## 2026-11-02 16:21 CET — Prepare dedicated worker launch

**What I did**

Removed the unchecked-worker opt-in and kept finite entry selection, realm and
Wire validation on both check and build. Check now visits the nested worker
graph without emitting files. Added the owner's type-only Calls and
CallsWithEvents aliases. Definition still requires stream = Worker.noStream:
a type alias cannot fill in a value-level record field.

Added worker skill topics with complete hosted and TEA programs, an event
observer, explicit Close and Abort, and child-fiber observation of interrupted
tickets. Updated the API and emission contracts to describe the built dedicated
runtime. The new aliases and ungated launch each failed with their implementation
stashed. The recipes and aliases ran in Chrome in development and release modes.
Prepared this as a draft launch for the owner to decide when to lift the gate.

**What I learned**

A worker's owner scope must remain alive after the handle enters the model.
An event-reader child can keep it alive. Stop that observer before cooperative
close. Abort must terminate the worker before the observer's cancellation lets
the owning scope return. An interrupted ticket ends its awaiting fiber, so use
Task.wait on a child when its parent must continue.

Skill refusal blocks need groups by diagnostic as well as platform. A frontend
Wire refusal can otherwise prevent static-entry and realm checks in the same
batch. Independent worker projections also need a selected worker root when a
check batch contains several page main declarations.
