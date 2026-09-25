import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import Home from "./pages/home";
import "./styles.css";

const legacyPath = window.location.hash.slice(1);
if (legacyPath.startsWith("/")) {
  window.history.replaceState({}, "", legacyPath);
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Home />
  </StrictMode>,
);
