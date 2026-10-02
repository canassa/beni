// solidjs/solid-todomvc's src/index.tsx (the official Solid 1 TodoMVC,
// ../../solid1/src/full.tsx) ported to Solid 2.0.0-rc.9 by its migration
// guide (references/solid/documentation/solid-2.0/MIGRATION.md): the store
// comes from `solid-js` with draft-first setters, the persisting effect is
// split into compute and apply, the `hashchange` listener lives in
// `onSettled` with its cleanup returned, `classList` is a `class` object,
// `use:setFocus` is a `ref`, and the bound `[handler, id]` events are
// closures. One addition: the filter is read from the address at start, as
// the other apps here do. There is no official Solid 2 TodoMVC: the
// `examples/todos` app in Solid's repository is an async, optimistic demo
// against a mock API that fails a third of its writes, not TodoMVC.
import { createEffect, createMemo, createStore, For, onSettled, Show } from "solid-js";
import { render } from "@solidjs/web";

const ESCAPE_KEY = 27;
const ENTER_KEY = 13;

const setFocus = (el) => setTimeout(() => el.focus());

const LOCAL_STORAGE_KEY = "todos-solid";
function createLocalStore(value) {
  // load stored todos on init
  const stored = localStorage.getItem(LOCAL_STORAGE_KEY),
    [state, setState] = createStore(stored ? JSON.parse(stored) : value);

  // JSON.stringify creates deps on every iterable field
  createEffect(
    () => JSON.stringify(state),
    (json) => localStorage.setItem(LOCAL_STORAGE_KEY, json),
  );
  return [state, setState];
}

const TodoApp = () => {
  const [state, setState] = createLocalStore({
      counter: 1,
      todos: [],
      showMode: location.hash.slice(2) || "all",
      editingTodoId: undefined,
    }),
    remainingCount = createMemo(
      () => state.todos.length - state.todos.filter((todo) => todo.completed).length,
    ),
    filterList = (todos) => {
      if (state.showMode === "active") return todos.filter((todo) => !todo.completed);
      else if (state.showMode === "completed") return todos.filter((todo) => todo.completed);
      else return todos;
    },
    removeTodo = (todoId) =>
      setState((s) => {
        s.todos = s.todos.filter((item) => item.id !== todoId);
      }),
    editTodo = (todo) =>
      setState((s) => {
        const item = s.todos.find((item) => item.id === todo.id);
        if (item) Object.assign(item, todo);
      }),
    clearCompleted = () =>
      setState((s) => {
        s.todos = s.todos.filter((todo) => !todo.completed);
      }),
    toggleAll = (completed) =>
      setState((s) => {
        for (const todo of s.todos) todo.completed = completed;
      }),
    setEditing = (todoId) =>
      setState((s) => {
        s.editingTodoId = todoId;
      }),
    addTodo = ({ target, keyCode }) => {
      const title = target.value.trim();
      if (keyCode === ENTER_KEY && title) {
        setState((s) => {
          s.todos = [{ title, id: s.counter, completed: false }, ...s.todos];
          s.counter++;
        });
        target.value = "";
      }
    },
    save = (todoId, { target: { value } }) => {
      const title = value.trim();
      if (state.editingTodoId === todoId && title) {
        editTodo({ id: todoId, title });
        setEditing();
      }
    },
    toggle = (todoId, { target: { checked } }) => editTodo({ id: todoId, completed: checked }),
    doneEditing = (todoId, e) => {
      if (e.keyCode === ENTER_KEY) save(todoId, e);
      else if (e.keyCode === ESCAPE_KEY) setEditing();
    };

  const locationHandler = () =>
    setState((s) => {
      s.showMode = location.hash.slice(2) || "all";
    });
  onSettled(() => {
    window.addEventListener("hashchange", locationHandler);
    return () => window.removeEventListener("hashchange", locationHandler);
  });

  return (
    <section class="todoapp">
      <header class="header">
        <h1>todos</h1>
        <input class="new-todo" placeholder="What needs to be done?" onKeyDown={addTodo} />
      </header>

      <Show when={state.todos.length > 0}>
        <section class="main">
          <input
            id="toggle-all"
            class="toggle-all"
            type="checkbox"
            checked={!remainingCount()}
            onInput={({ target: { checked } }) => toggleAll(checked)}
          />
          <label for="toggle-all" />
          <ul class="todo-list">
            <For each={filterList(state.todos)}>
              {(todo) => (
                <li
                  class={[
                    "todo",
                    { editing: state.editingTodoId === todo.id, completed: todo.completed },
                  ]}
                >
                  <div class="view">
                    <input
                      class="toggle"
                      type="checkbox"
                      checked={todo.completed}
                      onInput={(e) => toggle(todo.id, e)}
                    />
                    <label onDblClick={() => setEditing(todo.id)}>{todo.title}</label>
                    <button class="destroy" onClick={() => removeTodo(todo.id)} />
                  </div>
                  <Show when={state.editingTodoId === todo.id}>
                    <input
                      class="edit"
                      value={todo.title}
                      onFocusOut={(e) => save(todo.id, e)}
                      onKeyUp={(e) => doneEditing(todo.id, e)}
                      ref={setFocus}
                    />
                  </Show>
                </li>
              )}
            </For>
          </ul>
        </section>

        <footer class="footer">
          <span class="todo-count">
            <strong>{remainingCount()}</strong> {remainingCount() === 1 ? " item " : " items "}{" "}
            left
          </span>
          <ul class="filters">
            <li>
              <a href="#/" class={{ selected: state.showMode === "all" }}>
                All
              </a>
            </li>
            <li>
              <a href="#/active" class={{ selected: state.showMode === "active" }}>
                Active
              </a>
            </li>
            <li>
              <a href="#/completed" class={{ selected: state.showMode === "completed" }}>
                Completed
              </a>
            </li>
          </ul>
          <Show when={remainingCount() !== state.todos.length}>
            <button class="clear-completed" onClick={clearCompleted}>
              Clear completed
            </button>
          </Show>
        </footer>
      </Show>
    </section>
  );
};

render(TodoApp, document.getElementById("main"));
