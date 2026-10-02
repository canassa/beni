// ./full.jsx cut to the features tests/corpus/browser/tea/TodoMVC.beni
// has: no editing (no double-click, no edit field, no `editingTodoId`).
// Everything else is full.jsx's code, unchanged.
import { createEffect, createMemo, createStore, For, onSettled, Show } from "solid-js";
import { render } from "@solidjs/web";

const ENTER_KEY = 13;

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
    toggle = (todoId, { target: { checked } }) => editTodo({ id: todoId, completed: checked });

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
                <li class={["todo", { completed: todo.completed }]}>
                  <div class="view">
                    <input
                      class="toggle"
                      type="checkbox"
                      checked={todo.completed}
                      onInput={(e) => toggle(todo.id, e)}
                    />
                    <label>{todo.title}</label>
                    <button class="destroy" onClick={() => removeTodo(todo.id)} />
                  </div>
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
